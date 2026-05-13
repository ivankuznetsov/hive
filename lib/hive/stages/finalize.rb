require "fileutils"
require "open3"
require "hive/gh"
require "hive/markers"
require "hive/secret_patterns"
require "hive/stages/base"
require "hive/worktree"

module Hive
  module Stages
    module Finalize
      module_function

      def run!(task, cfg)
        marker = Hive::Markers.current(task.state_file)
        if marker.name == :complete && marker.attrs["is_draft"].to_s == "false"
          warn "hive: already complete; mv this folder to 8-done/ to continue"
          return { commit: nil, status: :complete }
        end

        pointer = worktree_pointer_or_exit(task)
        worktree_path = pointer.fetch("path")
        branch = pointer["branch"] || task.slug
        pr_url = pr_url_or_exit(task)

        state_result = verify_state!(task, worktree_path, branch)
        return state_result if state_result.is_a?(Hash)
        Hive::Gh.ensure_authenticated!

        prompt = render_prompt(task, worktree_path, branch, pr_url)
        profile = Hive::Stages::Base.stage_profile(cfg, "finalize")
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "finalize") || cfg.dig("budget_usd", "pr") || 50,
          timeout_sec: cfg.dig("timeout_sec", "finalize") || cfg.dig("timeout_sec", "pr") || 1800,
          log_label: "finalize",
          profile: profile
        )

        marker = Hive::Markers.current(task.state_file)
        return { commit: nil, status: marker.name } unless marker.name == :complete

        if (hits = scan_for_secrets(task, marker)).any?
          undo_ready(pr_url)
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_in_pr_body",
                            patterns: hits.map { |h| h[:name].to_s }.uniq.first(3).join(","))
          return { commit: "finalize_secret_blocked", status: :error }
        end

        write_summary(task, worktree_path, branch, pr_url)
        { commit: "pr_finalized", status: :complete }
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

      def pr_url_or_exit(task)
        pr_md = File.join(task.folder, "pr.md")
        unless File.exist?(pr_md)
          warn "hive: finalize entered without 5-open-pr's pr.md; re-create via hive run on a 5-open-pr task or move back"
          exit 1
        end

        url = Hive::Gh.pr_frontmatter(pr_md)["pr_url"]
        return url unless url.to_s.empty?

        warn "hive: finalize entered with pr.md missing pr_url; move back to 5-open-pr or repair pr.md"
        exit 1
      end

      def verify_state!(task, worktree_path, branch)
        out, _err, status = Open3.capture3("git", "-C", worktree_path, "status", "--porcelain")
        if !status.success? || !out.empty?
          Hive::Markers.set(task.state_file, :error, reason: "dirty_worktree")
          return { commit: "finalize_dirty_worktree", status: :error }
        end

        return true if pushed?(worktree_path, branch)

        Hive::Gh.push_branch!(worktree_path, branch)
        return true if pushed?(worktree_path, branch)

        Hive::Markers.set(task.state_file, :error, reason: "unpushed_commits")
        { commit: "finalize_unpushed_commits", status: :error }
      end

      def pushed?(worktree_path, branch)
        head, = capture_git(worktree_path, "rev-parse", "HEAD")
        upstream, = capture_git(worktree_path, "rev-parse", "#{branch}@{u}")
        !head.to_s.empty? && head == upstream
      end

      def capture_git(worktree_path, *args)
        out, _err, status = Open3.capture3("git", "-C", worktree_path, *args)
        [ status.success? ? out.strip : nil, status ]
      end

      def render_prompt(task, worktree_path, branch, pr_url)
        Hive::Stages::Base.render(
          "finalize_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: worktree_path,
            slug: task.slug,
            branch: branch,
            pr_url: pr_url,
            plan_text: read_optional(task, "plan.md"),
            reviews_summary: build_reviews_summary(task),
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

      def undo_ready(pr_url)
        Open3.capture3("gh", "pr", "ready", "--undo", pr_url)
      rescue StandardError
        nil
      end

      def write_summary(task, worktree_path, branch, pr_url)
        path = File.join(task.folder, "summary.md")
        body = Hive::Stages::Base.render(
          "finalize_summary.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            summary: extract_summary(task.state_file),
            pr_url: pr_url,
            commits: final_commits(worktree_path, branch),
            review: review_summary(task),
            open_escalations: open_escalations(task)
          )
        )
        File.write(path, body)
      end

      def extract_summary(pr_md)
        return "Final PR description refreshed." unless File.exist?(pr_md)

        body = File.read(pr_md)
        if body =~ /^## Summary\s*\n(.*?)(?:\n## |\n<!-- COMPLETE|\z)/m
          Regexp.last_match(1).strip
        else
          "Final PR description refreshed."
        end
      end

      def final_commits(worktree_path, branch)
        out, _err, status = Open3.capture3("git", "-C", worktree_path, "log", "--oneline", "#{branch}@{u}..HEAD")
        return "(branch is pushed; no unpushed commits)" if status.success? && out.strip.empty?
        return out.strip if status.success?

        out, _err, status = Open3.capture3("git", "-C", worktree_path, "log", "--oneline", "-10")
        status.success? ? out.strip : "(unable to read commits)"
      end

      def review_summary(task)
        passes = Dir[File.join(task.reviews_dir, "*-*.md")].filter_map do |path|
          File.basename(path).match(/-(\d{2})\.md\z/)&.[](1)&.to_i
        end
        max_pass = passes.max || 0
        "Review passes: #{max_pass}"
      end

      def open_escalations(task)
        paths = Dir[File.join(task.reviews_dir, "escalations-*.md")].sort
        unchecked = paths.flat_map do |path|
          File.readlines(path).grep(/^\s*-\s+\[\s*\]\s+/).map { |line| "#{File.basename(path)}: #{line.strip}" }
        rescue Errno::ENOENT
          []
        end
        unchecked.join("\n")
      end

      def read_optional(task, name)
        path = File.join(task.folder, name)
        File.exist?(path) ? File.read(path) : ""
      end

      def build_reviews_summary(task)
        return "(no reviews/ directory found)" unless File.directory?(task.reviews_dir)

        Dir[File.join(task.reviews_dir, "*.md")].sort.map do |f|
          "### #{File.basename(f)}\n#{File.read(f)}"
        end.join("\n\n")
      end
    end
  end
end
