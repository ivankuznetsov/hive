require "digest"
require "fileutils"
require "yaml"
require "hive/stages/base"
require "hive/worktree"
require "hive/git_ops"
require "hive/markers"

module Hive
  module Stages
    module Execute
      module_function

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
          puts "hive: already complete; mv this folder to 5-pr/ to continue"
          return { commit: nil, status: :execute_complete }
        when :stale
          warn "hive: EXECUTE_STALE — edit reviews/, lower pass:, remove the marker, then re-run"
          return { commit: nil, status: :execute_stale }
        when :worktree_missing
          warn "hive: worktree pointer present but worktree missing; recover with `git -C <root> worktree prune`, delete worktree.yml, then re-run"
          exit 1
        end

        if File.exist?(task.worktree_yml_path)
          run_iteration_pass(task, cfg)
        else
          run_init_pass(task, cfg)
        end
      end

      def task_state(task)
        marker = Hive::Markers.current(task.state_file)
        return :complete if marker.name == :execute_complete
        return :stale if marker.name == :execute_stale

        if File.exist?(task.worktree_yml_path)
          pointer = Hive::Worktree.read_pointer(task.folder) || {}
          path = pointer["path"]
          return :worktree_missing unless path && File.directory?(path)
        end
        :ready
      end

      # Canonical worktree_root for a task — never derived from agent-written
      # pointer paths. Mirrors the path used at init time.
      def canonical_worktree_root(task, cfg)
        cfg["worktree_root"] || File.expand_path("~/Dev/#{File.basename(task.project_root)}.worktrees")
      end

      def run_init_pass(task, cfg)
        ops = Hive::GitOps.new(task.project_root)
        worktree_root = canonical_worktree_root(task, cfg)
        wt = Hive::Worktree.new(task.project_root, task.slug, worktree_root: worktree_root)
        wt.create!(task.slug, default_branch: ops.default_branch)

        Hive::Worktree.validate_pointer_path(wt.path, worktree_root)
        wt.write_pointer!(task.folder, task.slug)

        write_initial_task_md(task)
        run_pass(task, cfg, wt.path, pass: 1, accepted_findings: nil)
      end

      def run_iteration_pass(task, cfg)
        worktree_root = canonical_worktree_root(task, cfg)
        pointer = Hive::Worktree.read_pointer(task.folder)
        worktree_path = pointer["path"]
        # Reject any pointer that escapes the canonical root — defends against
        # an agent rewriting worktree.yml to point at the master checkout.
        Hive::Worktree.validate_pointer_path(worktree_path, worktree_root)

        previous_pass = current_pass_from_reviews(task)
        max_passes = cfg["max_review_passes"] || 4
        pass = previous_pass + 1

        if previous_pass >= max_passes
          Hive::Markers.set(task.state_file, :execute_stale, max_passes: max_passes, pass: previous_pass)
          return { commit: "stale_max_passes", status: :execute_stale }
        end

        accepted = collect_accepted_findings(task, previous_pass)
        if accepted.strip.empty?
          Hive::Markers.set(task.state_file, :execute_complete, pass: previous_pass)
          return { commit: "complete_no_accepted", status: :execute_complete }
        end

        run_pass(task, cfg, worktree_path, pass: pass, accepted_findings: accepted)
      end

      # One iteration of impl + review, both wrapped in sha256 integrity checks
      # against PROTECTED_FILES. Either agent tampering with plan.md or
      # worktree.yml fails the run with marker :error.
      def run_pass(task, cfg, worktree_path, pass:, accepted_findings:)
        before_impl = sha256_for(task, PROTECTED_FILES)
        spawn_implementation(task, cfg, worktree_path, pass: pass, accepted_findings: accepted_findings)
        after_impl = sha256_for(task, PROTECTED_FILES)
        if (tampered = diff_hashes(before_impl, after_impl)).any?
          return record_tamper(task, tampered, who: "implementer")
        end

        before_review = sha256_for(task, PROTECTED_FILES)
        spawn_reviewer(task, cfg, worktree_path, pass: pass)
        after_review = sha256_for(task, PROTECTED_FILES)
        if (tampered = diff_hashes(before_review, after_review)).any?
          return record_tamper(task, tampered, who: "reviewer")
        end

        finalize_review_state(task, pass)
      end

      def spawn_implementation(task, cfg, worktree_path, pass:, accepted_findings:)
        plan_text = File.read(File.join(task.folder, "plan.md"))
        prompt = Hive::Stages::Base.render(
          "execute_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            worktree_path: worktree_path,
            task_folder: task.folder,
            pass: pass,
            plan_text: plan_text,
            accepted_findings: accepted_findings,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [task.folder],
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "execute_implementation"),
          timeout_sec: cfg.dig("timeout_sec", "execute_implementation"),
          log_label: "execute-impl-#{format('%02d', pass)}"
        )
      end

      def spawn_reviewer(task, cfg, worktree_path, pass:)
        ops = Hive::GitOps.new(task.project_root)
        prompt = Hive::Stages::Base.render(
          "review_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            worktree_path: worktree_path,
            task_folder: task.folder,
            default_branch: ops.default_branch,
            pass: pass
          )
        )
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [task.folder],
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "execute_review"),
          timeout_sec: cfg.dig("timeout_sec", "execute_review"),
          log_label: "execute-review-#{format('%02d', pass)}"
        )
      end

      def diff_hashes(before, after)
        before.keys.reject { |k| before[k] == after[k] }
      end

      def record_tamper(task, tampered, who:)
        Hive::Markers.set(task.state_file, :error,
                          reason: "#{who}_tampered",
                          files: tampered.join(","))
        { commit: "#{who}_tampered", status: :error }
      end

      # The orchestrator (not the agent) owns the terminal marker on task.md.
      # Pass count is derived from reviews/ce-review-*.md count, not from
      # frontmatter the agent has to remember to update.
      def finalize_review_state(task, pass)
        review_path = File.join(task.reviews_dir, format("ce-review-%02d.md", pass))
        if File.exist?(review_path)
          findings = count_findings(File.read(review_path))
          if findings.positive?
            Hive::Markers.set(task.state_file, :execute_waiting,
                              findings_count: findings, pass: pass)
            return { commit: "review_pass_#{format('%02d', pass)}_waiting",
                     status: :execute_waiting }
          end
        end

        Hive::Markers.set(task.state_file, :execute_complete, pass: pass)
        { commit: "review_pass_#{format('%02d', pass)}_complete",
          status: :execute_complete }
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

          ## Review History

          <!-- AGENT_WORKING -->
        MD
        File.write(task.state_file, content)
      end

      # Pass count = number of completed review files. The init pass writes
      # ce-review-01.md, the next iteration writes ce-review-02.md, etc. This
      # avoids any dependency on the agent updating task.md frontmatter.
      def current_pass_from_reviews(task)
        Dir[File.join(task.reviews_dir, "ce-review-*.md")].size
      end

      def count_findings(text)
        text.lines.count { |l| l =~ /^\s*-\s+\[[ x]\]\s+/ }
      end

      def collect_accepted_findings(task, previous_pass)
        review_path = File.join(task.reviews_dir, format("ce-review-%02d.md", previous_pass))
        return "" unless File.exist?(review_path)

        File.readlines(review_path).select { |l| l =~ /^\s*-\s+\[x\]\s+/ }.join
      end

      def sha256_for(task, names)
        names.each_with_object({}) do |name, h|
          path = File.join(task.folder, name)
          h[name] = File.exist?(path) ? Digest::SHA256.hexdigest(File.read(path)) : nil
        end
      end
    end
  end
end
