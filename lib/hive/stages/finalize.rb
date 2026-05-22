require "fileutils"
require "open3"
require "hive/gh"
require "hive/git_ops"
require "hive/markers"
require "hive/protected_files"
require "hive/secret_patterns"
require "hive/claude_launcher"
require "hive/stages"
require "hive/stages/base"
require "hive/worktree"

module Hive
  module Stages
    module Finalize
      module_function

      def run!(task, cfg)
        # Idempotency: summary.md is the terminal artifact. Using it
        # as the gate (rather than `is_draft=false` in the marker)
        # makes a partial completion that ran `gh pr ready` but
        # crashed before write_summary recoverable via `hive run`.
        if File.exist?(File.join(task.folder, "summary.md"))
          marker = Hive::Markers.current(task.state_file)
          warn "hive: already complete (#{marker.attrs['pr_url'] || '(no url)'}); " \
               "mv this folder to #{Hive::Stages::DIRS.last}/ to continue"
          return { commit: nil, status: :complete }
        end

        pointer = worktree_pointer_or_exit(task)
        worktree_path = pointer.fetch("path")
        branch = pointer["branch"] || task.slug
        pr_url, pr_error = pr_url_or_error(task)
        return pr_error if pr_error

        # Authenticate first so an auth-related push failure surfaces
        # as a clear "gh not authenticated" hard-fail (Plan R5)
        # instead of a generic git push error.
        Hive::Gh.ensure_authenticated!(cfg)
        state_result = verify_state!(task, worktree_path, branch, cfg)
        return state_result if state_result

        prompt = render_prompt(task, worktree_path, branch, pr_url)
        profile = Hive::Stages::Base.stage_profile(cfg, "finalize")
        before_sha = Hive::ProtectedFiles.snapshot(task.folder)
        spawn_finalize_agent(task, cfg, prompt, profile, worktree_path)
        after_sha = Hive::ProtectedFiles.snapshot(task.folder)
        if (tampered = Hive::ProtectedFiles.diff(before_sha, after_sha)).any?
          Hive::Markers.set(task.state_file, :error,
                            reason: "finalize_tampered", files: tampered.join(","))
          return { commit: "finalize_tampered", status: :error }
        end

        marker = Hive::Markers.current(task.state_file)
        return { commit: nil, status: marker.name } unless marker.name == :complete

        validation = validate_complete_marker(task, marker, pr_url)
        return validation if validation

        # Scan-before-ready: the runner OWNS the `gh pr ready` call so
        # the secret scan can gate it. The agent prompt now explicitly
        # forbids the agent from running `gh pr ready` (templates/
        # finalize_prompt.md.erb).
        scan = Hive::Gh.scan_pr_for_secrets(state_file: task.state_file,
                                            pr_url: pr_url,
                                            cfg: cfg)
        if scan.fetch_failed
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_scan_fetch_failed",
                            detail: scan.fetch_error.to_s[0, 200],
                            patterns: scan.hits.map { |h| h[:name].to_s }.uniq.first(3).join(","))
          return { commit: "finalize_secret_scan_failed", status: :error }
        end
        if scan.hits.any?
          redact_status = redact_pr_body!(pr_url, cfg)
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_in_pr_body",
                            patterns: scan.hits.map { |h| h[:name].to_s }.uniq.first(3).join(","),
                            redact_status: redact_status.to_s)
          return { commit: "finalize_secret_blocked", status: :error }
        end

        ready_result = mark_pr_ready(task, pr_url, cfg)
        return ready_result if ready_result

        write_summary(task, worktree_path, branch, pr_url)
        { commit: "pr_finalized", status: :complete }
      end

      def spawn_finalize_agent(task, cfg, prompt, profile, worktree_path)
        kwargs = {
          prompt: prompt,
          add_dirs: [ task.folder ],
          cwd: worktree_path,
          max_budget_usd: finalize_budget(cfg),
          timeout_sec: finalize_timeout(cfg),
          log_label: "finalize",
          profile: profile,
          status_mode: :state_file_marker
        }
        if profile.name == :claude
          Hive::Stages::Base.spawn_claude!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("8-finalize", task),
            allowed_tools: "Read,Write,Edit,Bash,LS,Glob,Grep"
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
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

      def pr_url_or_error(task)
        pr_md = File.join(task.folder, "pr.md")
        unless File.exist?(pr_md)
          warn "hive: finalize entered without 5-open-pr's pr.md; re-create via hive run on a 5-open-pr task or move back"
          Hive::Markers.set(task.state_file, :error,
                            reason: "missing_pr_md",
                            detail: "finalize requires pr.md from 5-open-pr")
          return [ nil, { commit: "finalize_missing_pr_md", status: :error } ]
        end

        url = Hive::Gh.pr_frontmatter(pr_md)["pr_url"]
        return [ url, nil ] unless url.to_s.empty?

        warn "hive: finalize entered with pr.md missing pr_url; move back to 5-open-pr or repair pr.md"
        Hive::Markers.set(task.state_file, :error,
                          reason: "missing_pr_url",
                          detail: "finalize requires pr_url frontmatter from 5-open-pr")
        [ nil, { commit: "finalize_missing_pr_url", status: :error } ]
      end

      def verify_state!(task, worktree_path, branch, cfg)
        out, err, status = Open3.capture3("git", "-C", worktree_path, "status", "--porcelain")
        unless status.success?
          Hive::Markers.set(task.state_file, :error,
                            reason: "git_status_failed",
                            detail: err.to_s.strip[0, 200])
          return { commit: "finalize_git_status_failed", status: :error }
        end
        unless out.empty?
          Hive::Markers.set(task.state_file, :error, reason: "dirty_worktree")
          return { commit: "finalize_dirty_worktree", status: :error }
        end

        return nil if pushed?(worktree_path, branch)

        push_result = Hive::Gh.push_branch(worktree_path, branch, cfg: cfg)
        return nil if push_result.success? && pushed?(worktree_path, branch)

        Hive::Markers.set(task.state_file, :error,
                          reason: "unpushed_commits",
                          detail: push_result.stderr.to_s.strip[0, 200])
        { commit: "finalize_unpushed_commits", status: :error }
      end

      def validate_complete_marker(task, marker, expected_pr_url)
        frontmatter_url = Hive::Gh.pr_frontmatter(task.state_file)["pr_url"].to_s
        if frontmatter_url != expected_pr_url.to_s
          Hive::Markers.set(task.state_file, :error,
                            reason: "finalize_pr_url_tampered",
                            expected_pr_url: expected_pr_url,
                            actual_pr_url: frontmatter_url)
          return { commit: "finalize_pr_url_tampered", status: :error }
        end

        marker_url = marker.attrs["pr_url"].to_s
        if marker_url != expected_pr_url.to_s
          Hive::Markers.set(task.state_file, :error,
                            reason: "finalize_pr_url_tampered",
                            expected_pr_url: expected_pr_url,
                            actual_pr_url: marker_url)
          return { commit: "finalize_pr_url_tampered", status: :error }
        end
        unless marker.attrs["is_draft"] == "false"
          Hive::Markers.set(task.state_file, :error,
                            reason: "finalize_marker_not_ready")
          return { commit: "finalize_marker_not_ready", status: :error }
        end

        nil
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

      # Runner-owned `gh pr ready` call. Runs only after secret scan
      # clears. Returns a stage result hash on failure, nil on success.
      def mark_pr_ready(task, pr_url, cfg)
        out, _err, status = Hive::Gh.capture3("gh", "pr", "view", pr_url, "--json", "isDraft", "-q", ".isDraft", cfg: cfg)
        return nil if status.success? && out.strip == "false"

        _out, err, status = Hive::Gh.capture3("gh", "pr", "ready", pr_url, cfg: cfg)
        return nil if status.success?
        return nil if err.to_s.include?("already") && err.to_s.include?("ready for review")

        Hive::Markers.set(task.state_file, :error,
                          reason: "gh_pr_ready_failed",
                          detail: err.to_s.strip[0, 200])
        { commit: "finalize_pr_ready_failed", status: :error }
      rescue Hive::GhError => e
        Hive::Markers.set(task.state_file, :error,
                          reason: "gh_pr_ready_failed",
                          detail: e.message.to_s[0, 200])
        { commit: "finalize_pr_ready_failed", status: :error }
      end

      # On secret hit, both revert ready AND scrub the body. Fail-loud
      # on revert failure so the operator sees the secret-bearing PR
      # is still public.
      def redact_pr_body!(pr_url, cfg)
        return :skipped if pr_url.to_s.empty?

        _out, err, status = Hive::Gh.capture3("gh", "pr", "edit", pr_url, "--body",
                                              "[redacted: hive detected a credential pattern]",
                                              cfg: cfg)
        unless status.success?
          warn "hive: failed to redact PR body for #{pr_url}: #{err.strip}"
          return :failed
        end
        :redacted
      rescue StandardError => e
        warn "hive: redact_pr_body raised #{e.class}: #{e.message}; PR body may still contain the secret"
        :failed
      end

      # Migration shim: read `budget_usd.pr` / `timeout_sec.pr` for one
      # version. `hive migrate` (Hive::Commands::Migrate::CONFIG_KEY_RENAMES)
      # rewrites these onto the canonical `.finalize` keys so the
      # fallback has a removal path. Slated for removal one version
      # after migrate ships.
      def finalize_budget(cfg)
        cfg.dig("budget_usd", "finalize") || cfg.dig("budget_usd", "pr") || 50
      end

      def finalize_timeout(cfg)
        cfg.dig("timeout_sec", "finalize") || cfg.dig("timeout_sec", "pr") || 1800
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
            open_escalations: open_escalations(task),
            slug: task.slug
          )
        )
        File.write(path, body)
      end

      def extract_summary(pr_md)
        return "Final PR description refreshed." unless File.exist?(pr_md)

        body = File.read(pr_md)
        if body =~ /^\#{1,3}\s+Summary\s*\n(.*?)(?:\n\#{1,3}\s+|\n<!-- COMPLETE|\z)/m
          Regexp.last_match(1).strip
        else
          "Final PR description refreshed."
        end
      end

      def final_commits(worktree_path, branch)
        default_branch = Hive::GitOps.new(worktree_path).default_branch
        base, = capture_git(worktree_path, "merge-base", "HEAD", "origin/#{default_branch}") if default_branch
        if base
          out, _err, status = Open3.capture3("git", "-C", worktree_path, "log", "--oneline", "#{base}..HEAD")
          return out.strip if status.success? && !out.strip.empty?
        end

        out, _err, status = Open3.capture3("git", "-C", worktree_path, "log", "--oneline", "-10")
        status.success? ? out.strip : "(unable to read commits)"
      end

      def review_summary(task)
        passes = Dir[File.join(task.reviews_dir, "*-*.md")].filter_map do |path|
          File.basename(path).match(/-(\d{2})\.md\z/)&.[](1)&.to_i
        end
        max_pass = passes.max || 0
        bias = nil
        triage_path = Dir[File.join(task.reviews_dir, "triage-*.md")].sort.last
        if triage_path
          File.read(triage_path) =~ /^bias:\s*(\S+)/i and bias = Regexp.last_match(1)
        end
        bias_line = bias ? "Triage bias: #{bias}" : "Triage bias: (unknown)"
        "Review passes: #{max_pass}\n#{bias_line}"
      end

      def open_escalations(task)
        paths = Dir[File.join(task.reviews_dir, "escalations-*.md")].sort
        unchecked = paths.flat_map do |path|
          File.readlines(path).grep(/^\s*-\s+\[\s*\]\s+/).map { |line| "#{File.basename(path)}: #{line.strip}" }
        rescue Errno::ENOENT
          warn "hive: escalations file #{path} disappeared mid-read; skipping"
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
