require "digest"
require "fileutils"
require "yaml"
require "hive/protected_files"
require "hive/stages/base"
require "hive/worktree"
require "hive/git_ops"
require "hive/markers"

module Hive
  module Stages
    # 4-execute stage runner. Implementation-only since U9 split the
    # review pass out into the new 5-review stage.
    #
    # Flow per `hive run` on a 4-execute task:
    #   1. Pre-flight: terminal markers, worktree pointer health.
    #   2. If no worktree.yml: create the feature worktree at
    #      <worktree_root>/<slug>, write the pointer.
    #   3. Spawn the implementation agent with plan.md as context. The
    #      agent edits the worktree and commits.
    #   4. Finalize: SHA-protect plan.md / worktree.yml around the spawn.
    #      On clean spawn → set EXECUTE_COMPLETE; on tamper → :error.
    #
    # User then `mv`s the task folder to .hive-state/stages/5-review/
    # to enter the autonomous review loop. There is no review pass
    # inside 4-execute anymore — the orchestrator-owned terminal
    # marker is EXECUTE_COMPLETE on success.
    module Execute
      module_function

      # 4-execute owns plan.md and worktree.yml; task.md is owned but
      # the implementer agent writes the AGENT_WORKING marker into it,
      # so it's deliberately NOT in the SHA-protected set here.
      PROTECTED_FILES = %w[plan.md worktree.yml].freeze

      def run!(task, cfg)
        plan_path = File.join(task.folder, "plan.md")
        unless File.exist?(plan_path)
          warn "hive: plan.md missing; this task did not pass through 3-plan"
          exit 1
        end

        FileUtils.mkdir_p(task.reviews_dir)

        case task_state(task)
        when :complete
          warn "hive: already complete; mv this folder to 5-review/ to continue"
          return { commit: nil, status: :execute_complete }
        when :worktree_missing
          warn "hive: worktree pointer present but worktree missing; recover with `git -C <root> worktree prune`, delete worktree.yml, then re-run"
          exit 1
        end

        if File.exist?(task.worktree_yml_path)
          run_continuation_pass(task, cfg)
        else
          run_init_pass(task, cfg)
        end
      end

      # Pre-flight state. EXECUTE_STALE is no longer a state 4-execute
      # writes (the review pass moved to 5-review).
      def task_state(task)
        marker = Hive::Markers.current(task.state_file)
        return :complete if marker.name == :execute_complete

        if File.exist?(task.worktree_yml_path)
          pointer = Hive::Worktree.read_pointer(task.folder) || {}
          path = pointer["path"]
          return :worktree_missing unless path && File.directory?(path)
        end
        :ready
      end

      # Canonical worktree_root for a task — never derived from
      # agent-written pointer paths. Mirrors the path used at init time.
      def canonical_worktree_root(task, cfg)
        cfg["worktree_root"] || File.expand_path("~/Dev/#{File.basename(task.project_root)}.worktrees")
      end

      # First entry into 4-execute: create the feature worktree, run
      # implementation, finalize.
      def run_init_pass(task, cfg)
        ops = Hive::GitOps.new(task.project_root)
        worktree_root = canonical_worktree_root(task, cfg)
        wt = Hive::Worktree.new(task.project_root, task.slug, worktree_root: worktree_root)
        wt.create!(task.slug, default_branch: ops.default_branch)

        Hive::Worktree.validate_pointer_path(wt.path, worktree_root)
        wt.write_pointer!(task.folder, task.slug)

        write_initial_task_md(task)
        run_pass(task, cfg, wt.path)
      end

      # User re-ran `hive run` on a 4-execute task whose worktree
      # already exists — re-validate the pointer and re-run the impl
      # spawn. Idempotent at the agent level (the agent re-reads
      # plan.md and continues / refines whatever was committed last
      # time).
      def run_continuation_pass(task, cfg)
        worktree_root = canonical_worktree_root(task, cfg)
        pointer = Hive::Worktree.read_pointer(task.folder)
        worktree_path = pointer["path"]
        Hive::Worktree.validate_pointer_path(worktree_path, worktree_root)

        run_pass(task, cfg, worktree_path)
      end

      # Spawn the implementation agent, SHA-protect plan.md /
      # worktree.yml around it, finalize EXECUTE_COMPLETE on clean
      # spawn or :error on tamper / agent failure.
      def run_pass(task, cfg, worktree_path)
        before_impl = Hive::ProtectedFiles.snapshot(task.folder, PROTECTED_FILES)
        impl_result = spawn_implementation(task, cfg, worktree_path)
        after_impl = Hive::ProtectedFiles.snapshot(task.folder, PROTECTED_FILES)

        if (tampered = Hive::ProtectedFiles.diff(before_impl, after_impl)).any?
          return record_tamper(task, tampered, who: "implementer")
        end

        return { commit: "implementer_failed", status: impl_result[:status] } if agent_failed?(impl_result)

        Hive::Markers.set(task.state_file, :execute_complete)
        { commit: "execute_complete", status: :execute_complete }
      end

      def agent_failed?(result)
        return true if result.nil?

        %i[error timeout].include?(result[:status])
      end

      def spawn_implementation(task, cfg, worktree_path)
        plan_text = File.read(File.join(task.folder, "plan.md"))
        prompt = Hive::Stages::Base.render(
          "execute_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            worktree_path: worktree_path,
            task_folder: task.folder,
            plan_text: plan_text,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "execute_implementation"),
          timeout_sec: cfg.dig("timeout_sec", "execute_implementation"),
          log_label: "execute-impl"
        )
      end

      def record_tamper(task, tampered, who:)
        Hive::Markers.set(task.state_file, :error,
                          reason: "#{who}_tampered",
                          files: tampered.join(","))
        { commit: "#{who}_tampered", status: :error }
      end

      def write_initial_task_md(task)
        return if File.exist?(task.state_file)

        content = <<~MD
          ---
          slug: #{task.slug}
          started_at: #{Time.now.utc.iso8601}
          ---

          # #{task.slug}

          ## Implementation

          <!-- AGENT_WORKING -->
        MD
        File.write(task.state_file, content)
      end
    end
  end
end
