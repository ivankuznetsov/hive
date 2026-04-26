require "open3"
require "timeout"
require "hive/stages/base"
require "hive/worktree"
require "hive/secret_patterns"

module Hive
  module Stages
    module Pr
      NETWORK_TIMEOUT_SEC = 60

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
            reviews_summary: reviews_summary,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )

        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "pr"),
          timeout_sec: cfg.dig("timeout_sec", "pr"),
          log_label: "pr"
        )

        marker = Hive::Markers.current(task.state_file)
        # Only commit on the success path. A stuck :agent_working / :error /
        # other marker is a real failure — don't pollute hive/state with
        # action='agent_working' commits that mask it.
        return { commit: nil, status: marker.name } unless marker.name == :complete

        if (hits = scan_for_secrets(task, marker)).any?
          # `hits` is an Array of `{name:, snippet:}` Hashes from
          # Hive::SecretPatterns.scan; first-three pattern *names* are the
          # useful breadcrumb (snippets are the actual secret material —
          # avoid logging them into hive/state).
          pattern_names = hits.map { |h| h[:name].to_s }.uniq.first(3).join(",")
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_in_pr_body",
                            patterns: pattern_names)
          return { commit: "pr_secret_blocked", status: :error }
        end

        { commit: "pr_opened", status: :complete }
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

      def ensure_gh_authenticated!
        out, err, status = with_network_timeout { Open3.capture3("gh", "auth", "status") }
        return if status.success?

        warn "hive: gh not authenticated (`gh auth login`):\n#{err.empty? ? out : err}"
        exit 1
      end

      def push_branch!(worktree_path, branch)
        out, err, status = with_network_timeout do
          Open3.capture3("git", "-C", worktree_path, "push", "-u", "origin", branch)
        end
        return if status.success?

        warn "hive: git push failed: #{err.strip.empty? ? out : err}"
        exit 1
      end

      def lookup_existing_pr(worktree_path, branch)
        # Include closed PRs too — a previous attempt that closed without
        # merging would otherwise create a duplicate on retry. Run with
        # chdir into the worktree so `gh` resolves the right repo regardless
        # of where `hive run` was invoked from.
        out, _err, status = with_network_timeout do
          Open3.capture3("gh", "pr", "list", "--head", branch,
                         "--state", "all", "--json", "url,number,state",
                         chdir: worktree_path)
        end
        return nil unless status.success?

        require "json"
        list = begin
          JSON.parse(out)
        rescue StandardError
          []
        end
        # Prefer open PRs; fall back to most recent for idempotency reporting.
        list.find { |p| p["state"] == "OPEN" } || list.first
      end

      def with_network_timeout(&block)
        Timeout.timeout(NETWORK_TIMEOUT_SEC, &block)
      rescue Timeout::Error
        warn "hive: network operation exceeded #{NETWORK_TIMEOUT_SEC}s; aborting"
        exit 1
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
