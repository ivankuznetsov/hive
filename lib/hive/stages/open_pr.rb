require "open3"
require "hive/gh"
require "hive/markers"
require "hive/protected_files"
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
        before_sha = Hive::ProtectedFiles.snapshot(task.folder)
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
        after_sha = Hive::ProtectedFiles.snapshot(task.folder)
        if (tampered = Hive::ProtectedFiles.diff(before_sha, after_sha)).any?
          Hive::Markers.set(task.state_file, :error,
                            reason: "open_pr_tampered", files: tampered.join(","))
          return { commit: "open_pr_tampered", status: :error }
        end

        marker = Hive::Markers.current(task.state_file)
        return { commit: nil, status: marker.name } unless marker.name == :complete

        validation = validate_complete_marker(task, marker, worktree_path, branch)
        return validation if validation

        scan = Hive::Gh.scan_pr_for_secrets(state_file: task.state_file,
                                            pr_url: marker.attrs["pr_url"])
        if scan.fetch_failed
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_scan_fetch_failed",
                            detail: scan.fetch_error.to_s[0, 200])
          return { commit: "open_pr_secret_scan_failed", status: :error }
        end
        if scan.hits.any?
          remediate_secret_leak!(marker.attrs["pr_url"])
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_in_pr_body",
                            patterns: scan.hits.map { |h| h[:name].to_s }.uniq.first(3).join(","))
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

      # Validate the agent-written COMPLETE marker against GitHub. An
      # agent that never called `gh pr create` but emitted a marker
      # with a fake URL would otherwise advance into 6-review and
      # surface only when `gh pr comment` hits a non-existent PR.
      # Returns a stage result hash on failure, nil when valid.
      def validate_complete_marker(task, marker, worktree_path, branch)
        marker_url = marker.attrs["pr_url"].to_s
        if marker_url.empty?
          Hive::Markers.set(task.state_file, :error, reason: "open_pr_marker_missing_url")
          return { commit: "open_pr_marker_missing_url", status: :error }
        end
        unless marker.attrs["is_draft"] == "true"
          Hive::Markers.set(task.state_file, :error, reason: "open_pr_not_draft")
          return { commit: "open_pr_not_draft", status: :error }
        end

        real = Hive::Gh.lookup_existing_pr(worktree_path, branch)
        unless real && real["url"] == marker_url
          Hive::Markers.set(task.state_file, :error,
                            reason: "open_pr_url_mismatch",
                            marker_url: marker_url,
                            real_url: real ? real["url"] : "(none)")
          return { commit: "open_pr_url_mismatch", status: :error }
        end

        nil
      end

      # On secret hit in the open PR body, scrub the body and close
      # the draft. Leaving a publicly-visible PR with the secret
      # negates the gate.
      def remediate_secret_leak!(pr_url)
        return if pr_url.to_s.empty?

        Open3.capture3("gh", "pr", "edit", pr_url, "--body",
                       "[redacted: hive detected a credential pattern]")
        Open3.capture3("gh", "pr", "close", pr_url)
      rescue StandardError => e
        warn "hive: failed to scrub leaked PR #{pr_url}: #{e.class}: #{e.message}; " \
             "manually edit and close it before resuming"
      end

      def write_pr_md(task, existing, idempotent: false)
        pr_url = existing["url"].to_s
        pr_number = existing["number"]
        if pr_url.empty?
          warn "hive: `gh pr list` returned a PR with an empty url; refusing to write pr.md"
          exit 1
        end
        is_draft = existing["isDraft"] == false ? "false" : "true"
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

          <!-- COMPLETE pr_url=#{pr_url} is_draft=#{is_draft}#{suffix} -->
        MD
      end

      def read_optional(task, name)
        path = File.join(task.folder, name)
        File.exist?(path) ? File.read(path) : ""
      end
    end
  end
end
