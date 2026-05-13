require "hive/gh"
require "hive/markers"
require "hive/secret_patterns"
require "hive/stages/base"
require "hive/worktree"

module Hive
  module Stages
    module OpenPr
      module_function

      def run!(task, cfg)
        pointer = worktree_pointer_or_exit(task)
        worktree_path = pointer.fetch("path")
        branch = pointer["branch"] || task.slug

        Hive::Gh.ensure_authenticated!

        existing = Hive::Gh.lookup_existing_pr(worktree_path, branch)
        if existing
          write_pr_md(task, existing, idempotent: true)
          return { commit: "open_pr_already_open", status: :complete }
        end

        Hive::Gh.push_branch!(worktree_path, branch)

        prompt = render_prompt(task, worktree_path, branch)
        profile = Hive::Stages::Base.stage_profile(cfg, "open_pr")
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "open_pr") || 50,
          timeout_sec: cfg.dig("timeout_sec", "open_pr") || 1800,
          log_label: "open-pr",
          profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        return { commit: nil, status: marker.name } unless marker.name == :complete

        if (hits = scan_for_secrets(task, marker)).any?
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_in_pr_body",
                            patterns: hits.map { |h| h[:name].to_s }.uniq.first(3).join(","))
          return { commit: "open_pr_secret_blocked", status: :error }
        end

        { commit: "pr_opened_draft", status: :complete }
      end

      def worktree_pointer_or_exit(task)
        pointer = Hive::Worktree.read_pointer(task.folder)
        unless pointer && pointer["path"]
          warn "hive: no worktree pointer; this task did not pass through 4-execute"
          exit 1
        end
        unless File.directory?(pointer["path"])
          warn "hive: worktree pointer at #{pointer['path']} no longer exists; recreate or move task back to 4-execute"
          exit 1
        end
        pointer
      end

      def render_prompt(task, worktree_path, branch)
        Hive::Stages::Base.render(
          "open_pr_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: worktree_path,
            slug: task.slug,
            branch: branch,
            plan_text: read_optional(task, "plan.md"),
            execute_output_text: read_optional(task, "task.md"),
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def scan_for_secrets(task, marker)
        sources = [ File.read(task.state_file) ]
        if (url = marker.attrs["pr_url"]) && !url.empty?
          out, _err, status = Open3.capture3("gh", "pr", "view", url, "--json", "body", "-q", ".body")
          sources << out if status.success? && !out.empty?
        end
        sources.flat_map { |s| Hive::SecretPatterns.scan(s) }
      rescue StandardError
        []
      end

      def write_pr_md(task, existing, idempotent: false)
        pr_url = existing["url"]
        pr_number = existing["number"]
        suffix = idempotent ? " idempotent=true" : ""
        File.write(task.state_file, <<~MD)
          ---
          pr_url: #{pr_url}
          pr_number: #{pr_number}
          ---

          ## Summary
          PR already open for this task.

          ## Linked task
          #{task.folder}

          <!-- COMPLETE pr_url=#{pr_url} is_draft=true#{suffix} -->
        MD
      end

      def read_optional(task, name)
        path = File.join(task.folder, name)
        File.exist?(path) ? File.read(path) : ""
      end
    end
  end
end
