require "open3"
require "hive/stages/base"
require "hive/worktree"

module Hive
  module Stages
    module Pr
      module_function

      def run!(task, cfg)
        pointer = Hive::Worktree.read_pointer(task.folder)
        unless pointer && pointer["path"]
          warn "hive: no worktree pointer; this task did not pass through 4-execute"
          exit 1
        end
        worktree_path = pointer["path"]
        unless File.directory?(worktree_path)
          warn "hive: worktree pointer at #{worktree_path} no longer exists; recreate or move task back to 4-execute"
          exit 1
        end

        ensure_gh_authenticated!
        push_branch!(worktree_path, pointer["branch"] || task.slug)

        existing = lookup_existing_pr(worktree_path, pointer["branch"] || task.slug)
        if existing
          write_pr_md(task, existing, idempotent: true)
          return { commit: "pr_already_open", status: :complete }
        end

        plan_text = read_optional(task, "plan.md")
        reviews_summary = build_reviews_summary(task)

        prompt = Hive::Stages::Base.render(
          "pr_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: worktree_path,
            slug: task.slug,
            plan_text: plan_text,
            reviews_summary: reviews_summary
          )
        )

        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [task.folder],
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "pr"),
          timeout_sec: cfg.dig("timeout_sec", "pr"),
          log_label: "pr"
        )

        marker = Hive::Markers.current(task.state_file)
        { commit: marker.name == :complete ? "pr_opened" : marker.name.to_s, status: marker.name }
      end

      def ensure_gh_authenticated!
        out, err, status = Open3.capture3("gh", "auth", "status")
        return if status.success?

        warn "hive: gh not authenticated (`gh auth login`):\n#{err.empty? ? out : err}"
        exit 1
      end

      def push_branch!(worktree_path, branch)
        out, err, status = Open3.capture3("git", "-C", worktree_path, "push", "-u", "origin", branch)
        return if status.success?

        warn "hive: git push failed: #{err.strip.empty? ? out : err}"
        exit 1
      end

      def lookup_existing_pr(_worktree_path, branch)
        out, _err, status = Open3.capture3("gh", "pr", "list", "--head", branch, "--state", "open",
                                           "--json", "url,number")
        return nil unless status.success?

        require "json"
        list = begin
          JSON.parse(out)
        rescue StandardError
          []
        end
        list.first
      end

      def write_pr_md(task, existing, idempotent: false)
        pr_md = task.state_file
        suffix = idempotent ? " idempotent=true" : ""
        File.write(pr_md, <<~MD)
          ---
          pr_url: #{existing['url']}
          pr_number: #{existing['number']}
          ---

          ## Summary
          PR already open for this task.

          ## Linked task
          #{task.folder}

          <!-- COMPLETE pr_url=#{existing['url']}#{suffix} -->
        MD
      end

      def read_optional(task, name)
        path = File.join(task.folder, name)
        File.exist?(path) ? File.read(path) : ""
      end

      def build_reviews_summary(task)
        reviews_dir = task.reviews_dir
        return "(no reviews/ directory found)" unless File.directory?(reviews_dir)

        Dir[File.join(reviews_dir, "*.md")].sort.map do |f|
          "### #{File.basename(f)}\n#{File.read(f)}"
        end.join("\n\n")
      end
    end
  end
end
