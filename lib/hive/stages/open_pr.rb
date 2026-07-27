require "open3"
require "hive/dependencies"
require "hive/dependency_snapshot"
require "hive/artifact_firewall"
require "hive/gh"
require "hive/git_ops"
require "hive/markers"
require "hive/secret_patterns"
require "hive/claude_launcher"
require "hive/stages/base"
require "hive/task"
require "hive/worktree"

module Hive
  module Stages
    module OpenPr
      module_function

      def run!(task, cfg)
        pointer = Hive::Stages::Base.worktree_pointer_or_exit(task)
        worktree_path = pointer.fetch("path")
        branch = pointer["branch"] || task.slug

        Hive::Gh.ensure_authenticated!(cfg)

        # Single `gh pr list` round-trip per stage entry. Earlier passes
        # called `lookup_existing_pr` and `lookup_merged_pr` separately,
        # each shelling out to `gh pr list --state all` — two network
        # hits with identical filter args. Pull the list once and branch
        # in-process. The OPEN-arm filter ALSO requires headRefOid to
        # match the local HEAD so a stale OPEN PR on a re-pushed branch
        # is not silently adopted; the merged-arm has carried that check
        # since the merged-recovery fix.
        #
        # Note: `Hive::Gh.lookup_existing_pr` and `lookup_merged_pr` are
        # still exported on the Gh module because callers like
        # `validate_complete_marker` (below) invoke them directly. The
        # de-duplication above only collapses the two-call pattern *inside*
        # `run!` — the helpers remain available for other call sites.
        prs = Hive::Gh.lookup_prs_for_branch(worktree_path, branch, cfg: cfg)
        head_oid = local_head_oid(worktree_path)
        existing = prs.find do |pr|
          pr["state"] == "OPEN" && (head_oid.nil? || pr["headRefOid"].to_s == head_oid.to_s)
        end
        if existing
          write_pr_md(task, existing, idempotent: true)
          marker = Hive::Markers.current(task.state_file)
          scan = Hive::Gh.scan_pr_for_secrets(state_file: task.state_file,
                                              pr_url: marker.attrs["pr_url"],
                                              cfg: cfg)
          return handle_secret_scan_result(task, marker.attrs["pr_url"], scan, "open_pr") if scan.fetch_failed || scan.hits.any?

          return { commit: "open_pr_already_open", status: :complete }
        end

        # A prior failed pass may have left an OPEN PR whose remote head no
        # longer matches the local branch. Scan every such remote body before
        # pushing or spawning another body-authoring agent; otherwise an hourly
        # retry could republish a credential before the next post-write scan.
        prs.select { |pr| pr["state"] == "OPEN" }.each do |pr|
          pr_url = pr["url"].to_s
          scan = Hive::Gh.scan_pr_for_secrets(
            state_file: task.state_file, pr_url: pr_url, cfg: cfg
          )
          result = handle_secret_scan_result(task, pr_url, scan, "open_pr")
          return result if result
        end

        merged = head_oid && prs.find { |pr| pr["state"] == "MERGED" && pr["headRefOid"].to_s == head_oid.to_s }
        if merged
          pr_url = merged["url"].to_s
          if pr_url.empty?
            warn "hive: `gh pr list` returned a merged PR with an empty url; refusing to recover"
            exit 1
          end

          # Write pr.md body upfront WITHOUT a terminal marker so
          # `scan_pr_for_secrets` (which `File.read`s state_file) has content
          # to scan. The COMPLETE marker is the commit point below — keeping
          # it last means any mid-sequence failure leaves pr.md non-terminal
          # and recovery re-enters on the next `hive run` instead of
          # advancing into a half-written cascade.
          File.write(task.state_file, pr_md_body(
            pr_url: pr_url,
            pr_number: merged["number"],
            head_oid: head_oid,
            summary_text: "PR already merged for this task.",
            task_folder: task.folder,
            marker_text: ""
          ))

          scan = Hive::Gh.scan_pr_for_secrets(state_file: task.state_file,
                                              pr_url: pr_url,
                                              cfg: cfg)
          return handle_secret_scan_result(task, pr_url, scan, "open_pr") if scan.fetch_failed || scan.hits.any?

          # Downstream short-circuit markers BEFORE the open-pr terminal
          # marker. They only become observable once the folder is advanced
          # past 5-open-pr, so writing them first is safe — and if either
          # File.write raises, pr.md is still non-terminal so the next run
          # re-enters the recovery path instead of advancing.
          write_merged_downstream_markers(task)

          # Commit point. Once this terminal marker lands, the open-pr stage
          # is "done" from the state-machine's perspective. write_merged_summary
          # is documentation only; its failure does not corrupt state.
          Hive::Markers.set(task.state_file, :complete,
                            pr_url: pr_url, is_draft: "false", merged: "true")

          write_merged_summary(task, merged)
          return { commit: "open_pr_already_merged", status: :complete }
        end

        local_scan = Hive::Gh.scan_pr_for_secrets(
          state_file: task.state_file, pr_url: "", cfg: cfg
        )
        local_result = handle_secret_scan_result(task, "", local_scan, "open_pr")
        return local_result if local_result

        Hive::Gh.push_branch!(worktree_path, branch, cfg: cfg)

        prompt = render_prompt(task, worktree_path, branch,
                               base_branch: dependency_pr_base_branch(task, cfg))
        identity = Hive::Stages::Base.implementation_stage_identity(task, cfg, "open_pr")
        profile = if identity
          Hive::AgentProfiles.lookup(identity.provider, cfg: cfg)
        else
          Hive::Stages::Base.stage_profile(cfg, "open_pr")
        end
        custody_manifest = Hive::ArtifactFirewall::Manifest.new(
          root: task.folder,
          protected_anchors: Hive::ArtifactFirewall::ORCHESTRATOR_OWNED,
          permitted_writable_roots: [ task.folder, worktree_path ]
        )
        custody_snapshot = Hive::ArtifactFirewall.capture(custody_manifest)
        begin
          spawn_open_pr_agent(
            task, cfg, prompt, profile, worktree_path, identity: identity
          )
        ensure
          custody_report = Hive::ArtifactFirewall.validate_and_restore(
            custody_manifest, custody_snapshot
          )
        end
        if custody_report.tampered?
          Hive::Markers.set(task.state_file, :error,
                            reason: "open_pr_tampered",
                            files: custody_report.tampered_labels.join(","),
                            restored: custody_report.restored?,
                            restore_error: custody_report.restore_diagnostic.to_s[0, 200])
          return { commit: "open_pr_tampered", status: :error }
        end

        marker = Hive::Markers.current(task.state_file)
        unless marker.name == :complete
          if [ :none, :agent_working ].include?(marker.name)
            Hive::Markers.set(task.state_file, :error, reason: "open_pr_marker_missing_complete")
            return { commit: "open_pr_marker_missing_complete", status: :error }
          end

          return { commit: nil, status: marker.name }
        end

        scan = Hive::Gh.scan_pr_for_secrets(state_file: task.state_file,
                                            pr_url: marker.attrs["pr_url"],
                                            cfg: cfg)
        scan_result = handle_secret_scan_result(task, marker.attrs["pr_url"], scan, "open_pr")
        return scan_result if scan_result

        validation = validate_complete_marker(task, marker, worktree_path, branch, cfg)
        return validation if validation

        { commit: "pr_opened_draft", status: :complete }
      end

      def spawn_open_pr_agent(task, cfg, prompt, profile, worktree_path, identity: nil)
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "open_pr", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
        )
        kwargs = {
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "open_pr") || 50,
          timeout_sec: cfg.dig("timeout_sec", "open_pr") || 1800,
          log_label: "open-pr",
          profile: profile,
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          status_mode: :state_file_marker,
          identity_arguments: identity&.native_arguments
        }
        if profile.name == :claude
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("5-open-pr", task) # coding-scoped: coding open-pr stage tmux session
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
      end

      def render_prompt(task, worktree_path, branch, base_branch: nil)
        Hive::Stages::Base.render(
          "open_pr_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            task_folder: task.folder,
            worktree_path: worktree_path,
            slug: task.slug,
            branch: branch,
            base_branch: base_branch,
            plan_text: read_optional(task, "plan.md"),
            execute_output_text: read_optional(task, "task.md"),
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def dependency_pr_base_branch(task, cfg)
        default_branch = cfg["default_branch"] || Hive::GitOps.new(task.project_root).default_branch
        base_branch = Hive::DependencySnapshot.stacked_base(task, default_branch)
        return nil unless base_branch

        # PR-specific extra guard (not shared with 4-execute): the PR base
        # must already exist on origin, else `gh pr create` would 422. A
        # resolved-but-unpushed prereq branch falls back to the default.
        Hive::Worktree.origin_branch_exists?(task.project_root, base_branch) ? base_branch : nil
      end

      # Validate the agent-written COMPLETE marker against GitHub. An
      # agent that never called `gh pr create` but emitted a marker
      # with a fake URL would otherwise advance into 6-review and
      # surface only when `gh pr comment` hits a non-existent PR.
      # Returns a stage result hash on failure, nil when valid.
      def validate_complete_marker(task, marker, worktree_path, branch, cfg)
        marker_url = marker.attrs["pr_url"].to_s
        if marker_url.empty?
          Hive::Markers.set(task.state_file, :error, reason: "open_pr_marker_missing_url")
          return { commit: "open_pr_marker_missing_url", status: :error }
        end
        unless marker.attrs["is_draft"] == "true"
          remediate_orphan_pr!(marker_url)
          Hive::Markers.set(task.state_file, :error, reason: "open_pr_not_draft")
          return { commit: "open_pr_not_draft", status: :error }
        end

        real = Hive::Gh.lookup_existing_pr(worktree_path, branch, cfg: cfg)
        unless real && real["url"] == marker_url
          remediate_orphan_pr!(marker_url)
          Hive::Markers.set(task.state_file, :error,
                            reason: "open_pr_url_mismatch",
                            marker_url: marker_url,
                            real_url: real ? real["url"] : "(none)")
          return { commit: "open_pr_url_mismatch", status: :error }
        end
        if real["isDraft"] == false
          remediate_orphan_pr!(marker_url)
          Hive::Markers.set(task.state_file, :error, reason: "open_pr_not_draft")
          return { commit: "open_pr_not_draft", status: :error }
        end
        local_head = local_head_oid(worktree_path).to_s.downcase
        remote_head = real["headRefOid"].to_s.downcase
        unless local_head.match?(/\A[a-f0-9]{40,64}\z/) &&
               remote_head == local_head
          remediate_orphan_pr!(marker_url)
          Hive::Markers.set(
            task.state_file, :error,
            reason: "open_pr_head_mismatch",
            local_head: local_head.empty? ? "(unavailable)" : local_head,
            remote_head: remote_head.empty? ? "(unavailable)" : remote_head
          )
          return { commit: "open_pr_head_mismatch", status: :error }
        end
        Hive::Gh.persist_pr_identity!(
          task.state_file,
          pr_url: marker_url,
          pr_number: real["number"],
          head_oid: remote_head
        )

        nil
      rescue Hive::GhError => e
        Hive::Markers.set(task.state_file, :error,
                          reason: "open_pr_lookup_failed",
                          detail: e.message.to_s[0, 200])
        { commit: "open_pr_lookup_failed", status: :error }
      end

      # On secret hit in the open PR body, scrub the body and close
      # the draft. Leaving a publicly-visible PR with the secret
      # negates the gate.
      def remediate_secret_leak!(pr_url)
        return if pr_url.to_s.empty?

        Hive::Gh.capture3("gh", "pr", "edit", pr_url, "--body",
                          "[redacted: hive detected a credential pattern]")
        Hive::Gh.capture3("gh", "pr", "close", pr_url)
      rescue StandardError => e
        warn "hive: failed to scrub leaked PR #{pr_url}: #{e.class}: #{e.message}; " \
             "manually edit and close it before resuming"
      end

      def remediate_orphan_pr!(pr_url)
        return if pr_url.to_s.empty?

        Hive::Gh.capture3("gh", "pr", "edit", pr_url, "--body",
                          "[redacted: hive rejected this PR state]")
        Hive::Gh.capture3("gh", "pr", "close", pr_url)
      rescue StandardError => e
        warn "hive: failed to close rejected PR #{pr_url}: #{e.class}: #{e.message}; " \
             "manually inspect it before resuming"
      end

      def handle_secret_scan_result(task, pr_url, scan, commit_prefix)
        if scan.fetch_failed
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_scan_fetch_failed",
                            detail: scan.fetch_error.to_s[0, 200],
                            patterns: scan.hits.map { |h| h[:name].to_s }.uniq.first(3).join(","))
          return { commit: "#{commit_prefix}_secret_scan_failed", status: :error }
        end
        if scan.hits.any?
          remediate_secret_leak!(pr_url)
          Hive::Markers.set(task.state_file, :error,
                            reason: "secret_in_pr_body",
                            patterns: scan.hits.map { |h| h[:name].to_s }.uniq.first(3).join(","))
          return { commit: "#{commit_prefix}_secret_blocked", status: :error }
        end

        nil
      end

      def local_head_oid(worktree_path)
        out, err, status = Open3.capture3("git", "-C", worktree_path, "rev-parse", "HEAD")
        unless status.success?
          warn "hive: open_pr: failed to read worktree HEAD at #{worktree_path}: #{err.to_s.strip}"
          return nil
        end

        out.strip.empty? ? nil : out.strip
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
        File.write(task.state_file, pr_md_body(
          pr_url: pr_url,
          pr_number: pr_number,
          head_oid: existing["headRefOid"],
          summary_text: "PR already open for this task.",
          task_folder: task.folder,
          marker_text: "<!-- COMPLETE pr_url=#{pr_url} is_draft=#{is_draft}#{suffix} -->"
        ))
      end

      # Shared body for pr.md. The already-open arm passes a baked-in
      # COMPLETE marker via `marker_text:`; the merged-recovery arm passes
      # an empty `marker_text:` and commits the COMPLETE marker via
      # `Hive::Markers.set` after downstream short-circuit markers land
      # (so a partial failure leaves pr.md non-terminal — see the
      # commit-point comment in `run!`).
      def pr_md_body(pr_url:, pr_number:, head_oid:, summary_text:, task_folder:, marker_text:)
        normalized_head = head_oid.to_s.downcase
        head_line = if normalized_head.match?(/\A[a-f0-9]{40,64}\z/)
          "head_oid: #{normalized_head}\n"
        else
          ""
        end
        <<~MD
          ---
          pr_url: #{pr_url}
          pr_number: #{pr_number}
          #{head_line}---

          ## Summary
          #{summary_text}

          ## Linked task
          #{task_folder}

          #{marker_text}
        MD
      end

      # Merged-recovery short-circuits 6-review and 7-artifacts so we don't
      # rerun reviewers / collect artifacts against an already-merged PR.
      # Without these markers, a user advancing the folder to 6-review
      # would see `Hive::Stages::Review.run!` ignore the absent task.md
      # terminal marker and re-spawn reviewers + CI against the merged PR.
      # Same logic for 7-artifacts and its artifact.md. The COMPLETE marker
      # used here mirrors what those stages would emit on their own happy
      # path so downstream consumers (Workflows, status) see one consistent
      # terminal shape.
      #
      # Cross-references for the short-circuit hand-off:
      # - `lib/hive/stages/review.rb` (~:102 case-when on `marker.name`,
      #   `:review_complete` branch) — observes the REVIEW_COMPLETE marker
      #   we land here on task.md and returns early without spawning.
      # - `lib/hive/stages/artifacts.rb` (~:14 `:complete` short-circuit
      #   guard) — observes the COMPLETE marker we land here on artifact.md.
      def write_merged_downstream_markers(task)
        review_state_file = File.join(task.folder, Hive::Task::STATE_FILES.fetch("review"))
        File.write(review_state_file, <<~MD)
          # Review skipped — PR merged before open-pr finished

          The PR for this task was merged on GitHub before the open-pr stage
          completed. The 6-review and 7-artifacts loops would otherwise re-run
          against the merged PR; this terminal marker short-circuits them.

          <!-- REVIEW_COMPLETE pass=0 browser=skipped merged=true -->
        MD

        artifact_state_file = File.join(task.folder, Hive::Task::STATE_FILES.fetch("artifacts"))
        File.write(artifact_state_file, <<~MD)
          # Artifacts skipped — PR merged before open-pr finished

          <!-- COMPLETE merged=true -->
        MD
      end

      def write_merged_summary(task, existing)
        pr_url = existing["url"].to_s
        pr_number = existing["number"]
        File.write(File.join(task.folder, "summary.md"), <<~MD)
          ## Summary
          PR ##{pr_number} was already merged before Hive finished the open-pr stage.

          PR: #{pr_url}

          ## Review
          Hive recovered the task from a stale open-pr state after confirming the PR is merged on GitHub.

          ## Open Escalations
          None.
        MD
      end

      def read_optional(task, name)
        path = File.join(task.folder, name)
        File.exist?(path) ? File.read(path) : ""
      end
    end
  end
end
