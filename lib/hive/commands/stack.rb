require "json"
require "yaml"
require "hive/config"
require "hive/dependencies"
require "hive/dependency_snapshot"
require "hive/git_ops"
require "hive/lock"
require "hive/plan_frontmatter"
require "hive/schemas"
require "hive/task_meta"
require "hive/task_resolver"

module Hive
  module Commands
    # `hive stack TARGET --on PREREQUISITE [--on PREREQUISITE ...]` sets, and
    # `hive stack TARGET --clear` removes, an existing task's `depends_on`
    # declaration at any unfinished stage. `hive new --depends-on` remains the
    # creation-time spelling; both write the same meta.yml field with the same
    # grammar, so status, the daemon, `hive run`, and forward `hive approve`
    # pick the change up through ordinary admission.
    #
    # Write-time validation matches creation: the grammar must parse and the
    # new edge must not close a cycle or point at the task itself. A missing
    # or otherwise unhealthy prerequisite is reported but still written,
    # because admission holds the task until it resolves. One check is
    # specific to an existing task: when its own plan.md frontmatter declares
    # a dependency, the requested declaration must match it exactly, or the
    # change would immediately park the task on `plan_dependency_mismatch`.
    #
    # The change never rebases an existing worktree branch. It gates
    # scheduling from now on and, for a same-project single prerequisite,
    # selects the base that execute and open-pr use when they next create a
    # worktree or PR.
    class Stack
      include Hive::Schemas::EnvelopeEmitter

      # A typed USAGE refusal; `error_kind` is one of StackErrorKind::ALL.
      class Refusal < Hive::UsageError
        attr_reader :error_kind

        def initialize(message, error_kind:)
          super(message)
          @error_kind = error_kind
        end
      end

      def initialize(target, on: nil, clear: false, project: nil, json: false)
        @target = target
        @on = Array(on).map(&:to_s)
        @clear = clear ? true : false
        @project = project
        @json = json
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema
        "hive-stack"
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      private

      def do_call
        declaration = requested_declaration
        task = Hive::TaskResolver.new(@target, project_filter: @project).resolve
        guard_unfinished!(task)
        guard_workflow!(task, declaration)
        project = registry_entry!(task)
        outcome = apply!(task, project, declaration)
        payload = success_payload(task, project, outcome)
        report(task, payload)
        payload
      rescue Hive::TaskMeta::InvalidMetadata => e
        raise Hive::ConfigError,
              "#{e.message}; hive stack only rewrites valid metadata, so repair meta.yml by hand first"
      end

      def requested_declaration
        if @clear && @on.any?
          raise Refusal.new("hive stack: pass either --on or --clear, not both",
                            error_kind: Hive::Schemas::StackErrorKind::USAGE)
        end
        unless @clear || @on.any?
          raise Refusal.new("hive stack: pass --on PREREQUISITE (repeatable) or --clear",
                            error_kind: Hive::Schemas::StackErrorKind::USAGE)
        end
        return nil if @clear

        raw = @on.length == 1 ? @on.first : @on
        Hive::Dependencies.normalize_declaration(raw)
      rescue Hive::Dependencies::InvalidReference => e
        raise Refusal.new(
          "invalid dependency #{Hive::Dependencies.display_declaration(raw)} — #{e.message}; expected a " \
          "prerequisite task id, slug, or explicit project:slug reference",
          error_kind: Hive::Schemas::StackErrorKind::INVALID_DEPENDENCY
        )
      end

      def guard_unfinished!(task)
        stage = stage_dir(task)
        return unless stage == task.workflow.stages.last.dir

        raise Hive::WrongStage.new(
          "#{task.slug} is in #{stage}; dependencies only apply to unfinished tasks",
          current_stage: stage
        )
      end

      def guard_workflow!(task, declaration)
        return if declaration.nil? || !task.workflow.draft_pr_handoff?

        raise Refusal.new(
          "workflow #{task.workflow.id} uses draft-PR handoff and does not support dependency stacking",
          error_kind: Hive::Schemas::StackErrorKind::UNSUPPORTED_WORKFLOW
        )
      end

      # Admission requires plan.md frontmatter, when it declares a
      # dependency, to equal meta.yml exactly. Writing a different value
      # would trade one admission error for another, so refuse and name the
      # file to edit. Malformed frontmatter is a pre-existing admission error
      # this command neither causes nor fixes; the verdict reports it.
      def guard_plan_agreement!(task, declaration)
        plan_path = File.join(task.folder, "plan.md")
        plan = Hive::PlanFrontmatter.read(plan_path)
        return unless plan.status == :ok && !plan.depends_on.nil?

        declared = Hive::Dependencies.serialize_declaration(plan.depends_on)
        return if declared == declaration

        shown = Hive::Dependencies.display_declaration(declared)
        if declaration.nil?
          reason = "plan_dependency_missing"
          correction = "Remove depends_on from the YAML frontmatter of #{plan_path}, then rerun hive stack --clear."
        else
          reason = "plan_dependency_mismatch"
          correction = "Change depends_on in the YAML frontmatter of #{plan_path} to " \
                       "#{Hive::Dependencies.display_declaration(declaration)}, then rerun hive stack."
        end
        raise Hive::DependencyAdmissionError.new(
          "#{task.slug}'s plan.md declares depends_on #{shown}; meta.yml must match it, " \
          "or admission holds the task (#{reason})",
          reason_code: reason, offending_ref: shown, safe_correction: correction
        )
      end

      def registry_entry!(task)
        root = File.expand_path(task.project_root)
        matches = Hive::Config.registered_projects.select do |entry|
          File.expand_path(entry.fetch("path")) == root
        end
        return matches.first if matches.one?

        raise Hive::ConfigError,
              "#{root} is #{matches.empty? ? 'not enrolled' : 'enrolled more than once'}; " \
              "dependency admission needs exactly one registry entry (see hive init / hive prune)"
      end

      Outcome = Data.define(:previous, :declaration, :changed, :committed, :verdict)

      # Custody order mirrors other metadata writers: observe the task, take
      # the project commit lock, then the task lease, and re-check identity at
      # each step. A live stage agent holds the lease, so this raises the
      # retryable ConcurrentRunError instead of editing under it.
      def apply!(task, project, declaration)
        Hive::TaskMeta.with_observation(task.folder) do |observation|
          raise stale_error(task) unless observation

          Hive::Lock.with_commit_lock(task.hive_state_path) do
            Hive::TaskMeta.validate_observation!(task.folder, observation)
            Hive::Lock.with_task_lock(
              task.folder, slug: task.slug, op: "stack", create: false, observation: observation
            ) do
              previous = Hive::TaskMeta.read_for_update!(task.folder)[:depends_on]
              guard_plan_agreement!(task, declaration)
              verdict = Hive::DependencySnapshot.proposed_dependency_verdict(
                project: project, slug: task.slug, depends_on: declaration
              )
              if previous == declaration
                next Outcome.new(previous: previous, declaration: declaration,
                                 changed: false, committed: false, verdict: verdict)
              end

              refuse_cycle!(verdict)
              committed = write_and_commit!(task, observation, declaration)
              Outcome.new(previous: previous, declaration: declaration,
                          changed: true, committed: committed, verdict: verdict)
            end
          end
        end
      end

      def refuse_cycle!(verdict)
        error = verdict.admission_error
        return unless error&.cycle?

        raise Refusal.new(
          "refusing to stack: dependency cycle #{error.offending_ref}",
          error_kind: Hive::Schemas::StackErrorKind::DEPENDENCY_CYCLE
        )
      end

      # The metadata change and its hive/state commit land together: a
      # failed commit restores the previous meta.yml bytes before re-raising,
      # so the on-disk declaration never diverges from recorded history.
      def write_and_commit!(task, observation, declaration)
        before = Hive::TaskMeta.snapshot(task.folder)
        result = Hive::TaskMeta.rewrite(task.folder, { depends_on: declaration }, observation: observation)
        raise stale_error(task) if result.stale?

        begin
          Hive::GitOps.new(task.project_root).hive_commit(
            stage_name: stage_dir(task), slug: task.slug, action: commit_action(declaration)
          ) == :committed
        rescue Hive::GitError, Hive::ConcurrentRunError
          Hive::TaskMeta.restore(task.folder, before, observation: observation, create: false)
          raise
        end
      end

      def commit_action(declaration)
        case declaration
        when nil then "unstacked"
        when Array then "depends on #{declaration.join(', ')}"
        else "stacked on #{declaration}"
        end
      end

      def stale_error(task)
        Hive::TaskMeta::StaleTask.new(
          "#{task.slug} moved or changed identity while its dependency was being updated; retry"
        )
      end

      def stage_dir(task)
        File.basename(File.dirname(task.folder))
      end

      def success_payload(task, project, outcome)
        verdict = outcome.verdict
        {
          "schema" => "hive-stack",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-stack"),
          "ok" => true,
          "project" => project.fetch("name").to_s,
          "slug" => task.slug,
          "id" => Hive::TaskMeta.read(task.folder)[:id],
          "stage" => stage_dir(task),
          "depends_on" => outcome.declaration,
          "previous_depends_on" => outcome.previous,
          "changed" => outcome.changed,
          "committed" => outcome.committed,
          "dependency" => {
            "state" => verdict_state(verdict),
            "unmet_dependencies" => verdict.unmet_dependencies.map(&:to_h),
            "admission_error" => verdict.admission_error&.to_h
          }.tap do |dep|
            roots = verdict.dependency_repair_roots.first(64).map(&:to_h)
            dep["dependency_repair_roots"] = roots unless roots.empty?
          end,
          "notes" => notes(task, project, outcome)
        }
      end

      def verdict_state(verdict)
        return "clear" if verdict.clear?
        return "wait" if verdict.wait?

        "admission_error"
      end

      def notes(task, project, outcome)
        declaration = outcome.declaration
        notes = []
        if declaration.is_a?(Array)
          notes << "multiple prerequisites are scheduling-only: each must reach 9-done, and the task " \
                   "branches from the project default instead of stacking on one of them"
        elsif declaration && Hive::Dependencies.parse_reference(declaration).explicit_project
          notes << "an explicit project:slug prerequisite gates scheduling only; the task branch is not " \
                   "stacked on it"
        end
        if outcome.changed && (base = existing_worktree_base(task))
          notes << "#{task.slug} already has a worktree branched from #{base}; Hive does not rebase it, so " \
                   "this change gates scheduling from now on but does not move the code on that branch"
        end
        error = outcome.verdict.admission_error
        if error && !error.cycle?
          notes << "#{task.slug} is held until this resolves: #{error.reason_code} " \
                   "(#{error.offending_ref}). #{error.safe_correction}"
        end
        notes
      end

      def existing_worktree_base(task)
        return nil unless File.exist?(task.worktree_yml_path)

        data = YAML.safe_load(File.read(task.worktree_yml_path), permitted_classes: [], aliases: false)
        return "its recorded base" unless data.is_a?(Hash)

        (data["base_ref"] || data["base_branch"] || "its recorded base").to_s
      rescue Psych::Exception, SystemCallError, IOError
        "its recorded base"
      end

      def report(task, payload)
        if @json
          puts JSON.generate(payload)
          @stdout_written = true
          return
        end

        puts headline(task, payload)
        dependency = payload.fetch("dependency")
        repair_roots = Array(dependency["dependency_repair_roots"])
        repair_roots.each do |root|
          puts "  waiting for repair at #{Hive::Dependencies.repair_root_summary(root)}"
        end
        dependency.fetch("unmet_dependencies").each do |unmet|
          target = unmet["blocked_by"] || unmet["reference"]
          next if repair_roots.any? do |root|
            Hive::Dependencies.repair_root_matches_target?(
              root, target, current_project: payload["project"]
            )
          end

          puts "  waiting for #{target} " \
               "(#{unmet['dependency_stage'] || 'stage unknown'}) to reach #{unmet['required_gate']}"
        end
        if payload["depends_on"] && dependency.fetch("state") == "clear"
          puts "  not blocked: every prerequisite has reached its gate"
        end
        payload.fetch("notes").each { |note| warn "hive: note: #{note}" }
      end

      def headline(task, payload)
        declaration = payload.fetch("depends_on")
        shown = declaration.is_a?(Array) ? declaration.join(", ") : declaration
        unless payload.fetch("changed")
          return declaration ? "#{task.slug} already depends on #{shown}; nothing changed" :
                               "#{task.slug} has no dependency; nothing changed"
        end

        case declaration
        when nil then "#{task.slug} no longer depends on another task"
        when Array then "#{task.slug} now depends on #{shown}"
        else "#{task.slug} now stacked on #{shown}"
        end
      end

      def error_kind_for(error)
        kinds = Hive::Schemas::StackErrorKind
        case error
        when Refusal                          then error.error_kind
        when Hive::DependencyAdmissionError   then kinds::PLAN_CONFLICT
        when Hive::AmbiguousSlug              then kinds::AMBIGUOUS_SLUG
        when Hive::InvalidTaskPath            then kinds::INVALID_TASK_PATH
        when Hive::WrongStage                 then kinds::WRONG_STAGE
        when Hive::TaskMeta::StaleTask        then kinds::STALE_TASK
        when Hive::ConcurrentRunError         then kinds::CONCURRENT_RUN
        when Hive::ConfigError                then kinds::CONFIG
        when Hive::GitError                   then kinds::GIT
        when Hive::UsageError                 then kinds::USAGE
        when Hive::InternalError              then kinds::INTERNAL
        else                                       kinds::ERROR
        end
      end
    end
  end
end

# The pre-dispatch JSON usage contract for this command boundary: Thor
# rejections that never reach the handler still ride this command's JSON
# envelope (see Hive::CliUsageContracts).
require "hive/cli_usage_contracts"

Hive::CliUsageContracts.declare("stack", { schema: "hive-stack", error_kind: "usage" })
