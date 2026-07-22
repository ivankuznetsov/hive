require "hive/config"
require "hive/atomic_file"
require "hive/draft_pr_receipt"
require "hive/gh"
require "hive/markers"
require "hive/protected_files"
require "hive/stages/agent"
require "hive/stages/agent_report"
require "hive/stages/draft_pr_handoff"
require "hive/stages/base"
require "hive/worktree"
require "open3"

module Hive
  module Stages
    # Controller-owned setup for the closed workspace:worktree +
    # handoff:draft_pr stage contract. U3 consumes Context to run and validate
    # the mapped agent; U4 advances the receipt through remote handoff phases.
    module AgentWorktree
      module_function

      MAX_INSTRUCTION_CHARS = 16_000
      MAX_INSTRUCTION_BYTES = MAX_INSTRUCTION_CHARS * 4
      MANAGED_AGENT_FAILURE_REASON = "managed_agent_failed".freeze
      PROTECTED_FILES = (
        Hive::ProtectedFiles::ORCHESTRATOR_OWNED + %w[meta.yml handoff.yml pr.md]
      ).uniq.freeze

      Context = Data.define(
        :worktree_path, :task_branch, :base_branch, :base_oid, :repository
      )

      def run!(task, cfg)
        stage = task.workflow.stage_named(task.stage_name)
        stage or raise Hive::StageError, "no agent stage #{task.stage_name}"
        report_path = report_path!(task, stage)
        validate_protected_files!(task.folder)
        if (receipt = terminal_receipt(task))
          return Hive::Stages::DraftPrHandoff.resume_terminal!(task, receipt)
        end

        context = prepare!(task, cfg)
        receipt = Hive::DraftPrReceipt.read(
          task.folder, worktree_root: File.dirname(context.worktree_path)
        )
        if receipt.fetch("phase") == "terminal"
          return Hive::Stages::DraftPrHandoff.resume_terminal!(task, receipt)
        end
        unless receipt.fetch("phase") == Hive::DraftPrReceipt::INITIAL_PHASE
          source = Hive::Stages::DraftPrHandoff.report_source_for_resume(
            report_path, expected_sha256: receipt.fetch("report_sha256")
          )
          report = Hive::Stages::AgentReport.parse(source)
          repository_state = Hive::Stages::AgentReport.validate_repository!(report, context)
          return Hive::Stages::DraftPrHandoff.run!(
            task, context: context, report: report,
            repository_state: repository_state, report_source: source, cfg: cfg || {}
          )
        end
        prepare_report_output!(report_path)

        profile = Hive::Stages::Base.stage_profile(
          cfg || {}, task.stage_name, explicit_agent: stage.agent
        )
        prompt = render_prompt(task, stage, context, report_path)
        permission_kwargs = stage.permissions.nil? ? {} : { explicit_permission_spec: stage.permissions }
        prompt, scope = Hive::Stages::Base.actor_prompt_and_scope(
          cfg || {}, task.stage_name, task, profile,
          prompt: prompt,
          base_add_dirs: [ context.worktree_path, task.folder ],
          managed_slot: "stages.#{stage.name}",
          **permission_kwargs
        )
        resource_limits = Hive::Stages::Base.stage_resource_limits(cfg || {}, stage)

        git_control_paths = git_control_paths!(context.worktree_path)
        git_controls_before = Hive::ProtectedFiles.snapshot_paths(git_control_paths)
        protected_before = Hive::ProtectedFiles.snapshot(task.folder, PROTECTED_FILES)
        result = nil
        spawn_error = nil
        begin
          result = Hive::Stages::Base.spawn_agent(
            task,
            prompt: prompt,
            add_dirs: scope.fetch(:add_dirs),
            cwd: context.worktree_path,
            **resource_limits,
            log_label: task.stage_name,
            profile: profile,
            model: stage.model,
            effort: stage.effort,
            **Hive::Stages::Base.tool_scope_kwargs(scope),
            status_mode: :exit_code_only,
            cfg: cfg || {}
          )
        rescue StandardError => e
          spawn_error = e
        ensure
          protected_after = Hive::ProtectedFiles.snapshot(task.folder, PROTECTED_FILES)
          git_controls_after = Hive::ProtectedFiles.snapshot_paths(git_control_paths)
        end
        tampered = Hive::ProtectedFiles.diff(protected_before, protected_after)
        unless tampered.empty?
          raise Hive::StageError,
                "worktree agent modified protected task files: #{tampered.join(', ')}"
        end
        git_tampered = Hive::ProtectedFiles.diff(git_controls_before, git_controls_after)
        unless git_tampered.empty?
          raise Hive::StageError,
                "worktree agent modified protected Git control files: #{git_tampered.join(', ')}"
        end
        return managed_failure_result(task, error: spawn_error, context: context) if spawn_error

        unless result.is_a?(Hash) && result[:status] == :ok
          return managed_failure_result(task, result: result, context: context)
        end

        report_source = Hive::Stages::AgentReport.read_source(report_path)
        report = Hive::Stages::AgentReport.parse(report_source)
        repository_state = Hive::Stages::AgentReport.validate_repository!(report, context)
        Hive::Stages::DraftPrHandoff.run!(
          task, context: context, report: report,
          repository_state: repository_state, report_source: report_source, cfg: cfg || {}
        ).merge(
          worktree_context: context, report: report,
          repository_state: repository_state, agent_result: result
        )
      rescue Hive::StageError, Hive::WorktreeError, Hive::GhError => e
        managed_failure_result(task, error: e)
      end

      def managed_failure_result(task, result: nil, error: nil, context: nil)
        result = result.is_a?(Hash) ? result : {}
        reason = if !result[:limit_text].to_s.empty?
          "limits_reached"
        elsif result[:timed_out] || result[:status] == :timeout
          "timeout"
        elsif result[:resource_exhaustion].is_a?(Hash)
          result[:resource_exhaustion][:reason].to_s.empty? ? MANAGED_AGENT_FAILURE_REASON :
            result[:resource_exhaustion][:reason].to_s
        else
          MANAGED_AGENT_FAILURE_REASON
        end
        attrs = {
          reason: reason,
          message: "The managed repair agent did not produce a controller-validated result."
        }
        attrs[:exception_class] = error.class.name if error
        write_failure_marker!(task, attrs)
        result.merge(
          status: :error, commit: reason, worktree_context: context,
          error: error&.class&.name
        ).compact
      end
      private_class_method :managed_failure_result

      def write_failure_marker!(task, attrs)
        path = File.join(task.folder, "fix-report.md")
        # The failed report is untrusted and may itself be a symlink or contain
        # credentials. Replace it with a controller-only marker while keeping
        # the isolated repository/worktree intact for manual inspection.
        Hive::AtomicFile.write(path, "", mode: 0o600)
        Hive::Markers.set(path, :error, attrs)
        File.chmod(0o600, path)
      end
      private_class_method :write_failure_marker!

      def git_control_paths!(worktree_path)
        common = git_path!(worktree_path, "--path-format=absolute", "--git-common-dir")
        git_dir = git_path!(worktree_path, "--absolute-git-dir")
        paths = {
          "worktree .git pointer" => File.join(worktree_path, ".git"),
          "repository config" => File.join(common, "config"),
          "worktree config" => File.join(git_dir, "config.worktree")
        }
        home = ENV["HOME"].to_s
        unless home.empty?
          paths["global Git config"] = File.join(home, ".gitconfig")
          paths["XDG Git config"] = File.join(home, ".config", "git", "config")
        end
        xdg = ENV["XDG_CONFIG_HOME"].to_s
        paths["explicit XDG Git config"] = File.join(xdg, "git", "config") unless xdg.empty?
        global = ENV["GIT_CONFIG_GLOBAL"].to_s
        paths["global Git config override"] = global unless global.empty?
        system = ENV["GIT_CONFIG_SYSTEM"].to_s
        paths["system Git config override"] = system unless system.empty?
        paths
      end
      private_class_method :git_control_paths!

      def git_path!(worktree_path, *args)
        out, err, status = Open3.capture3("git", "-C", worktree_path, "rev-parse", *args)
        unless status.success?
          detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
          raise Hive::StageError, "managed worktree Git control path is unavailable: #{detail[0, 200]}"
        end

        File.expand_path(out.to_s.strip, worktree_path)
      end
      private_class_method :git_path!

      def terminal_receipt(task)
        receipt_path = Hive::DraftPrReceipt.path(task.folder)
        return nil unless File.exist?(receipt_path) || File.symlink?(receipt_path)

        root = Hive::Worktree.new(task.project_root, task.slug).worktree_root
        receipt = Hive::DraftPrReceipt.read(task.folder, worktree_root: root)
        receipt.fetch("phase") == "terminal" ? receipt : nil
      end
      private_class_method :terminal_receipt

      def render_prompt(task, stage, context, report_path)
        instruction = read_instruction(stage)
        tag = Hive::Stages::Base.user_supplied_tag
        prior = Hive::Stages::Agent.prior_artifacts(task, File.basename(report_path))
        Hive::Stages::Base.render(
          "agent_worktree_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            worktree_path: context.worktree_path,
            repository: context.repository,
            task_branch: context.task_branch,
            base_branch: context.base_branch,
            base_oid: context.base_oid,
            report_path: report_path,
            instruction_body: instruction,
            prior_context: prior,
            user_supplied_tag: tag
          )
        )
      end

      def read_instruction(stage)
        return nil unless stage.instruction

        body = File.open(stage.instruction, File::RDONLY | File::NOFOLLOW) do |file|
          raise Hive::StageError, "worktree agent instruction must be a regular file" unless file.stat.file?

          file.read(MAX_INSTRUCTION_BYTES + 1)
        end
        if body.bytesize > MAX_INSTRUCTION_BYTES
          raise Hive::StageError,
                "worktree agent instruction exceeds #{MAX_INSTRUCTION_CHARS} characters"
        end
        if body.length > MAX_INSTRUCTION_CHARS
          raise Hive::StageError,
                "worktree agent instruction exceeds #{MAX_INSTRUCTION_CHARS} characters"
        end
        body
      rescue SystemCallError, IOError => e
        raise Hive::StageError,
              "worktree agent instruction is unreadable: #{e.class}: #{e.message}"
      end
      private_class_method :read_instruction

      def report_path!(task, stage)
        relative = stage.deliverable || stage.state_file
        path = File.expand_path(File.join(task.folder, relative.to_s))
        unless File.dirname(path) == File.expand_path(task.folder) && File.basename(path) == "fix-report.md"
          raise Hive::StageError,
                "draft-PR agent deliverable must be task-root fix-report.md"
        end
        path
      end
      private_class_method :report_path!

      def prepare_report_output!(path)
        stat = File.lstat(path)
        raise Hive::StageError, "fix-report.md must be a regular file, not a symlink" if stat.symlink?
        raise Hive::StageError, "fix-report.md must be a regular file" unless stat.file?

        File.unlink(path)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError, IOError => e
        raise Hive::StageError, "could not prepare fix-report.md: #{e.class}: #{e.message}"
      end
      private_class_method :prepare_report_output!

      def validate_protected_files!(task_folder)
        PROTECTED_FILES.each do |name|
          stat = File.lstat(File.join(task_folder, name))
          unless stat.file? && !stat.symlink?
            raise Hive::StageError,
                  "protected task file #{name} must be a regular file"
          end
        rescue Errno::ENOENT
          next
        end
      end
      private_class_method :validate_protected_files!

      def prepare!(task, cfg)
        if task.depends_on
          raise Hive::WorktreeError,
                "draft-PR worktree tasks do not support depends_on stacking"
        end

        base_branch = Hive::Worktree.validate_branch_name!(task.base_branch)
        repository = controller_repository!(task.project_root, cfg)
        fetch_repository = controller_fetch_repository!(task.project_root, cfg)
        unless fetch_repository == repository
          raise Hive::WorktreeError,
                "origin fetch repository #{fetch_repository} does not match push repository #{repository}"
        end
        Hive::Gh.ensure_authenticated!(cfg, host: "github.com")

        worktree = Hive::Worktree.new(task.project_root, task.slug)
        root = worktree.worktree_root
        pointer_path = File.join(task.folder, "worktree.yml")
        receipt_path = Hive::DraftPrReceipt.path(task.folder)
        pointer_exists = File.exist?(pointer_path) || File.symlink?(pointer_path)
        receipt_exists = File.exist?(receipt_path) || File.symlink?(receipt_path)
        if pointer_exists != receipt_exists
          raise Hive::WorktreeError,
                "draft-PR worktree state is incomplete; preserving pointer, receipt, branch, and worktree"
        end

        # Exact remote availability is preflighted on every run. A later base
        # advance does not rewrite the saved baseline: resumes validate the
        # recorded OID's ancestry instead.
        observed_base_oid = worktree.fetch_strict_origin_base!(base_branch)
        if pointer_exists
          resume_context!(
            task, cfg, worktree, root,
            base_branch: base_branch, repository: repository
          )
        else
          create_context!(
            task, worktree, root,
            base_branch: base_branch, base_oid: observed_base_oid,
            repository: repository
          )
        end
      end

      def controller_repository!(path, cfg)
        identity = Hive::Gh.repository_identity(path, cfg: cfg)
        host = identity.fetch("host").to_s.downcase
        raise Hive::WorktreeError, "draft-PR handoff supports github.com repositories only" unless host == "github.com"

        "#{host}/#{identity.fetch('repository').to_s.downcase}"
      rescue KeyError => e
        raise Hive::WorktreeError, "could not resolve canonical origin repository: #{e.message}"
      end
      private_class_method :controller_repository!

      def controller_fetch_repository!(path, cfg)
        out, err, status = Hive::Gh.capture3(
          "git", "-C", path, "remote", "get-url", "--all", "origin", cfg: cfg
        )
        unless status.success?
          raise Hive::WorktreeError,
                "could not read origin fetch URL: #{err.to_s.strip.empty? ? out : err}"
        end
        urls = out.lines.map(&:strip).reject(&:empty?)
        unless urls.one?
          raise Hive::WorktreeError, "origin fetch URL lookup returned #{urls.length} records; expected exactly one"
        end
        identity = Hive::Gh.repository_identity_from_remote(urls.first)
        host = identity.fetch("host").to_s.downcase
        raise Hive::WorktreeError, "draft-PR handoff supports github.com repositories only" unless host == "github.com"

        "#{host}/#{identity.fetch('repository').to_s.downcase}"
      rescue Hive::GhError, KeyError => e
        raise Hive::WorktreeError, "could not resolve canonical origin fetch repository: #{e.message}"
      end
      private_class_method :controller_fetch_repository!

      def create_context!(task, worktree, root, base_branch:, base_oid:, repository:)
        worktree.create_strict_origin!(
          task.slug, base_branch: base_branch, base_oid: base_oid
        )
        pointer = {
          "path" => worktree.path,
          "branch" => task.slug,
          "base_branch" => base_branch,
          "base_oid" => base_oid,
          "repository" => repository
        }
        worktree.write_pointer!(
          task.folder, task.slug,
          base_branch: base_branch, base_oid: base_oid, repository: repository
        )
        receipt = receipt_from(pointer)
        Hive::DraftPrReceipt.initialize!(task.folder, expected: receipt, worktree_root: root)
        validate_repository_match!(worktree.path, repository)
        context_from(pointer)
      end
      private_class_method :create_context!

      def resume_context!(task, cfg, worktree, root, base_branch:, repository:)
        expected = {
          "path" => worktree.path,
          "branch" => task.slug,
          "base_branch" => base_branch,
          "repository" => repository
        }
        pointer = Hive::Worktree.read_strict_pointer(
          task.folder, expected_root: root, expected: expected
        )
        Hive::DraftPrReceipt.read(
          task.folder, expected_identity: receipt_from(pointer), worktree_root: root
        )
        worktree.validate_strict_resume!(
          branch_name: task.slug, base_oid: pointer.fetch("base_oid")
        )
        validate_repository_match!(worktree.path, repository, cfg: cfg)
        context_from(pointer)
      end
      private_class_method :resume_context!

      def validate_repository_match!(worktree_path, expected, cfg: nil)
        actual = controller_repository!(worktree_path, cfg)
        return if actual == expected

        raise Hive::WorktreeError,
              "worktree repository #{actual} does not match recorded repository #{expected}"
      end
      private_class_method :validate_repository_match!

      def receipt_from(pointer)
        {
          "version" => Hive::DraftPrReceipt::VERSION,
          "phase" => Hive::DraftPrReceipt::INITIAL_PHASE,
          "repository" => pointer.fetch("repository"),
          "base_branch" => pointer.fetch("base_branch"),
          "base_oid" => pointer.fetch("base_oid"),
          "task_branch" => pointer.fetch("branch"),
          "worktree_path" => pointer.fetch("path")
        }
      end
      private_class_method :receipt_from

      def context_from(pointer)
        Context.new(
          worktree_path: pointer.fetch("path"),
          task_branch: pointer.fetch("branch"),
          base_branch: pointer.fetch("base_branch"),
          base_oid: pointer.fetch("base_oid"),
          repository: pointer.fetch("repository")
        )
      end
      private_class_method :context_from
    end
  end
end
