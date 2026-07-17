require "fileutils"
require "open3"
require "time"
require "digest"
require "hive/gh"
require "hive/git_ops"
require "hive/markers"
require "hive/protected_files"
require "hive/secret_patterns"
require "hive/claude_launcher"
require "hive/stages"
require "hive/stages/base"
require "hive/stages/clean_exit"
require "hive/worktree"
require "hive/attempts/context"
require "hive/attempts/store"
require "hive/babysitter/job_store"
require "hive/task_journal"
require "hive/task_projection/store"

module Hive
  module Stages
    module Finalize
      HandoffResult = Data.define(:job, :event, :projection)

      module_function

      def run!(task, cfg)
        pointer = worktree_pointer_or_exit(task)
        worktree_path = pointer.fetch("path")
        branch = pointer["branch"] || task.slug
        pr_url, pr_error = pr_url_or_error(task)
        return pr_error if pr_error
        snapshot, snapshot_error = exact_snapshot_or_error(task, pr_url, cfg)
        return snapshot_error if snapshot_error

        # summary.md is presentation, not authority. A retry repairs or adopts
        # the durable handoff and deliberately performs no branch/PR mutation.
        existing_finalization = Hive::TaskProjection::Store.new(task_folder: task.folder).read["finalization"]
        if File.exist?(File.join(task.folder, "summary.md")) ||
           existing_finalization.fetch("state") != "unfinalized"
          _handoff, handoff_error = establish_handoff_or_error(task, cfg, snapshot, branch)
          return handoff_error if handoff_error
          write_summary(task, worktree_path, branch, pr_url, cfg) unless File.exist?(File.join(task.folder, "summary.md"))
          marker = Hive::Markers.current(task.state_file)
          warn "hive: already complete (#{marker.attrs['pr_url'] || '(no url)'}); " \
               "babysitter watching is active"
          return { commit: nil, status: :complete }
        end

        # Already merged is still a handoff. Finalize records no merge event;
        # the claimed babysitter job will observe the exact MERGED snapshot.
        if snapshot.state == "MERGED"
          _handoff, handoff_error = establish_handoff_or_error(task, cfg, snapshot, branch)
          return handoff_error if handoff_error
          Hive::Markers.set(task.state_file, :complete,
                            pr_url: pr_url, is_draft: "false", merged: "true")
          write_summary(task, worktree_path, branch, pr_url, cfg)
          return { commit: "finalize_handed_off_merged", status: :complete }
        end

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

        snapshot, snapshot_error = exact_snapshot_or_error(task, pr_url, cfg)
        return snapshot_error if snapshot_error
        _handoff, handoff_error = establish_handoff_or_error(task, cfg, snapshot, branch)
        return handoff_error if handoff_error
        write_summary(task, worktree_path, branch, pr_url, cfg)
        { commit: "pr_finalized", status: :complete }
      end

      def spawn_finalize_agent(task, cfg, prompt, profile, worktree_path)
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "finalize", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
        )
        kwargs = {
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: worktree_path,
          max_budget_usd: finalize_budget(cfg),
          timeout_sec: finalize_timeout(cfg),
          log_label: "finalize",
          profile: profile,
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          status_mode: :state_file_marker
        }
        if profile.name == :claude
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("8-finalize", task) # coding-scoped: coding finalize stage tmux session
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

      def exact_snapshot_or_error(task, pr_url, cfg)
        [ Hive::Gh.exact_pr_snapshot(pr_url, cfg: cfg), nil ]
      rescue Hive::GhError => e
        Hive::Markers.set(task.state_file, :error,
                          reason: "github_unavailable", detail: e.message.to_s[0, 200])
        [ nil, { commit: "finalize_github_unavailable", status: :error } ]
      end

      def establish_handoff_or_error(task, cfg, snapshot, branch)
        [ establish_handoff!(task, cfg, snapshot, branch), nil ]
      rescue StandardError => e
        Hive::Markers.set(task.state_file, :error,
                          reason: "finalize_handoff_failed", detail: "#{e.class}: #{e.message}"[0, 200])
        [ nil, { commit: "finalize_handoff_failed", status: :error } ]
      end

      def establish_handoff!(task, cfg, snapshot, branch, now: Time.now.utc)
        context = Hive::Attempts::Context.current
        raise Hive::StageError, "finalize handoff requires a durable attempt context" unless context

        store = Hive::Babysitter::JobStore.new(project_root: task.project_root)
        projection_store = Hive::TaskProjection::Store.new(task_folder: task.folder)
        finalization = projection_store.read["finalization"]
        current_job = if finalization.fetch("state") == "unfinalized"
          nil
        else
          store.read(finalization.fetch("job_id"))
        end

        if current_job && same_pr?(current_job, snapshot)
          event = adopt_or_repair_handoff!(
            task, store, projection_store, current_job, context, snapshot, now: now
          )
          return verified_handoff(store, projection_store, current_job.fetch("job_id"), event)
        end

        job = if current_job
          old_snapshot = Hive::Gh.exact_pr_snapshot(finalization.fetch("pr_url"), cfg: cfg)
          store.reserve_replacement!(
            old_job_id: current_job.fetch("job_id"), remote_state: old_snapshot.state,
            remote_observed_at: old_snapshot.observed_at,
            **reservation_attributes(task, cfg, context, snapshot, branch, now)
          )
        else
          store.reserve!(**reservation_attributes(task, cfg, context, snapshot, branch, now))
        end
        event = append_finalize_event!(
          task, context, snapshot, job,
          type: "finalized", now: now,
          extra_payload: current_job ? {
            "supersedes_job_id" => current_job.fetch("job_id"),
            "replacement_proof" => job.fetch("replacement_proof")
          } : {}
        )
        store.activate!(
          job.fetch("job_id"), handoff_event_id: event.fetch("event_id"),
          finalize_attempt_id: context.attempt_id, now: now
        )
        verified_handoff(store, projection_store, job.fetch("job_id"), event)
      end

      def adopt_or_repair_handoff!(task, store, projection_store, job, context, snapshot, now:)
        projection = projection_store.read["finalization"]
        if projection.fetch("finalize_attempt_id") == context.attempt_id
          event_id = projection.dig("evidence", "finalized_event_id")
          event = Hive::TaskProjection.read_journal(
            File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
          ).find { |record| record["event_id"] == event_id }
          store.activate!(
            job.fetch("job_id"), handoff_event_id: event_id,
            finalize_attempt_id: context.attempt_id, now: now
          ) if job.fetch("state") == "inactive"
          return event
        end

        event = append_finalize_event!(
          task, context, snapshot, job,
          type: "finalize_attempt_adopted", now: now
        )
        store.adopt_attempt!(
          job.fetch("job_id"), handoff_event_id: event.fetch("event_id"),
          finalize_attempt_id: context.attempt_id, now: now
        )
        event
      end

      def append_finalize_event!(task, context, snapshot, job, type:, now:, extra_payload: {})
        event_id = deterministic_handoff_event_id(type, job.fetch("job_id"), context.attempt_id)
        payload = handoff_coordinates(job, context, snapshot).merge(extra_payload)
        producer = { "kind" => "finalize_attempt", "attempt_id" => context.attempt_id }
        existing = Hive::TaskProjection.read_journal(
          File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
        ).find { |record| record["event_id"] == event_id }
        if existing
          unless existing["event_type"] == type && existing["producer"] == producer && existing["payload"] == payload
            raise Hive::TaskJournal::EventIdCollision, "handoff event identity has divergent content"
          end
          return existing
        end

        attributes = {
          event_id: event_id,
          event_type: type,
          occurred_at: now.utc.iso8601(6),
          observed_at: snapshot.observed_at,
          task: { "id" => task.id, "slug" => task.slug },
          workflow: task.workflow.id,
          stage: "8-finalize",
          attempt_id: context.attempt_id,
          task_generation: context.task_generation,
          ownership_generation: context.ownership_generation,
          commit_generation: nil,
          reason: type == "finalized" ? "finalize_handoff" : "finalize_attempt_adoption",
          evidence: [ {
            "type" => "pull_request", "url" => snapshot.url, "number" => snapshot.number,
            "observed_head_sha" => snapshot.head_sha, "state" => snapshot.state,
            "observed_at" => snapshot.observed_at
          } ],
          provenance: { "source" => "finalize", "snapshot" => "exact_pr" },
          producer: producer,
          payload: payload
        }
        writer = Hive::TaskJournal::Writer.new(
          task_folder: task.folder, attempt_store: finalize_attempt_store
        )
        writer.append_once(attributes).records.fetch(0)
      end

      def finalize_attempt_store
        root = ENV["HIVE_ATTEMPT_STORE_ROOT"].to_s
        root.empty? ? Hive::Attempts::Store.new : Hive::Attempts::Store.new(root: root)
      end

      def reservation_attributes(task, cfg, context, snapshot, branch, now)
        {
          project: cfg["project_name"] || File.basename(task.project_root),
          task_id: task.id || task.slug,
          task_slug: task.slug,
          task_generation: context.task_generation,
          repository: snapshot.repository,
          pr_number: snapshot.number,
          pr_url: snapshot.url,
          branch: branch,
          head_sha: snapshot.head_sha,
          head_generation: 1,
          finalize_attempt_id: context.attempt_id,
          task_folder: task.folder,
          now: now
        }
      end

      def handoff_coordinates(job, context, snapshot)
        {
          "job_id" => job.fetch("job_id"),
          "repository" => snapshot.repository,
          "pr_number" => snapshot.number,
          "pr_url" => snapshot.url,
          "head_sha" => snapshot.head_sha,
          "head_generation" => job.fetch("head_generation"),
          "finalize_attempt_id" => context.attempt_id
        }
      end

      def deterministic_handoff_event_id(type, job_id, attempt_id)
        digest = Digest::SHA256.hexdigest([ type, job_id, attempt_id ].join("\0"))[0, 32]
        "finalization-#{type}-#{digest}"
      end

      def same_pr?(job, snapshot)
        identity = job.fetch("identity")
        identity.fetch("repository") == snapshot.repository && identity.fetch("pr_number") == snapshot.number
      end

      def verified_handoff(store, projection_store, job_id, event)
        job = store.read(job_id)
        projection = projection_store.rebuild!["finalization"]
        unless job.fetch("state") == "active" && projection.fetch("job_id") == job_id &&
               projection.fetch("finalize_attempt_id") == job.fetch("finalize_attempt_id")
          raise Hive::StageError, "finalize handoff did not converge"
        end
        HandoffResult.new(job: job, event: event, projection: projection)
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
        # Defense-in-depth backstop. Stages already enforce a clean
        # worktree at exit via Hive::Stages::Base.with_stage_events, but
        # finalize is the last gate before push — and existing in-flight
        # features that landed at 8-finalize *before* the invariant
        # shipped must still self-heal. Residue passing the scope check
        # is auto-committed as `chore(8-finalize): commit residual
        # worktree changes`; scope-violating residue (or a git failure)
        # lands `:error reason=ensure_clean_on_exit_failed` so the bot
        # routes it to manual-only recovery instead of looping retries.
        unless out.empty?
          result = Hive::Stages::CleanExit.run!(
            worktree_path: worktree_path,
            stage: "8-finalize", # coding-scoped: coding finalize stage event
            task: task,
            cfg: cfg || {},
            reason: :finalize_entry_backstop
          )
          case result[:status]
          when :auto_committed
            log_finalize_residue_committed(task, result)
            # Fall through to the push / pushed? logic below — the
            # residue is now part of the branch history.
          when :scope_violation, :git_failed
            attrs = {
              reason: "ensure_clean_on_exit_failed",
              detail: result[:message].to_s[0, 200]
            }
            attrs[:residue_paths] = Array(result[:paths]).join(",")[0, 200] if result[:paths]
            Hive::Markers.set(task.state_file, :error, **attrs)
            return { commit: "finalize_dirty_worktree", status: :error }
          when :clean
            # status said dirty but CleanExit saw clean — race with an
            # operator who committed manually between the two reads.
            # Continue to the push gate.
          end
        end

        return nil if pushed?(worktree_path, branch)

        push_result = Hive::Gh.push_branch(worktree_path, branch, cfg: cfg)
        return nil if push_result.success? && pushed?(worktree_path, branch)

        # A remote-side auto-rebase (the PR branch rebased onto an advanced
        # base while this worktree stayed on the old base) leaves HEAD
        # diverged from its upstream even though every local commit's CHANGE
        # is already on the remote as a patch-identical rebase. The push above
        # then fails non-fast-forward and finalize would loop on
        # unpushed_commits forever — yet the work is safely on the PR branch.
        # Detect that case and fast-forward the worktree to its upstream
        # instead of erroring.
        return nil if resync_stale_rebase!(worktree_path, branch)

        # The branch was auto-rebased (e.g. during review): history was
        # rewritten while real local fix commits accrued, so the plain push is
        # non-fast-forward and resync_stale_rebase! (local already on remote by
        # patch-id) does not apply. Force-push ONLY when HEAD is a superset of
        # its upstream — every commit on the remote is already present in HEAD
        # by patch-id — so nothing remote-only is clobbered (--force-with-lease
        # additionally aborts on a concurrent third-party update). A genuinely
        # diverged upstream (a commit whose change is NOT in HEAD) falls
        # through to the error below, preserving that work for a human.
        forced = nil
        if head_supersedes_upstream?(worktree_path, branch)
          forced = Hive::Gh.push_branch(worktree_path, branch, cfg: cfg, force: true)
          return nil if forced.success? && pushed?(worktree_path, branch)
        end

        Hive::Markers.set(task.state_file, :error,
                          reason: "unpushed_commits",
                          detail: ((forced&.stderr).to_s.strip.empty? ? push_result.stderr : forced.stderr).to_s.strip[0, 200])
        { commit: "finalize_unpushed_commits", status: :error }
      end

      # True only when HEAD already contains, by patch-id, every commit on the
      # branch's upstream — so force-pushing HEAD cannot drop remote-only work.
      # `git cherry HEAD <upstream>` lists upstream commits relative to HEAD; a
      # `+` marks an upstream commit whose change is NOT in HEAD (genuine
      # divergence), so any `+` — or a git failure — returns false and the
      # caller errors instead of force-pushing over real work.
      def head_supersedes_upstream?(worktree_path, branch)
        cherry, status = capture_git(worktree_path, "cherry", "HEAD", "#{branch}@{u}")
        return false unless status.success?

        cherry.to_s.lines.none? { |line| line.start_with?("+") }
      end

      # Fast-forward a worktree whose local commits are all already on the
      # upstream by patch-id — the stale side of a remote auto-rebase.
      # Returns true (and hard-resets the worktree to its upstream) only when
      # NO local commit carries a change missing from the upstream: `git
      # cherry` marks an already-present change `-` and a genuinely-missing
      # one `+`, so any `+` (real unpushed work) or a git failure returns
      # false and the caller errors rather than discarding work.
      def resync_stale_rebase!(worktree_path, branch)
        upstream = "#{branch}@{u}"
        cherry, status = capture_git(worktree_path, "cherry", upstream, "HEAD")
        return false unless status.success?
        return false if cherry.to_s.lines.any? { |line| line.start_with?("+") }

        _out, reset_status = capture_git(worktree_path, "reset", "--hard", upstream)
        return false unless reset_status.success?

        warn "[hive] finalize: fast-forwarded stale rebase-duplicate worktree to #{upstream}"
        true
      end

      # Record an auto-committed-residue event under the task's log dir so
      # the operator scanning logs can tell the residue commit was
      # produced by the finalize backstop (vs. a per-stage `stage_exit`
      # hook). Best-effort — log-write failure must not abort finalize.
      def log_finalize_residue_committed(task, result)
        return unless task.respond_to?(:log_dir)

        FileUtils.mkdir_p(task.log_dir)
        ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        path = File.join(task.log_dir, "finalize-residue-committed-#{ts}.log")
        body = <<~LOG
          finalize backstop auto-committed worktree residue
          head: #{result[:head]}
          commit_subject: #{result[:commit_subject]}
          paths:
          #{Array(result[:paths]).map { |p| "  - #{p}" }.join("\n")}
        LOG
        File.write(path, body)
      rescue StandardError => e
        warn "[hive] finalize-residue log write failed: #{e.class}: #{e.message}"
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

      def write_summary(task, worktree_path, branch, pr_url, cfg = nil)
        path = File.join(task.folder, "summary.md")
        body = Hive::Stages::Base.render(
          "finalize_summary.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            summary: extract_summary(task.state_file),
            pr_url: pr_url,
            commits: final_commits(worktree_path, branch),
            review: review_summary(task, cfg),
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

      def review_summary(task, cfg = nil)
        passes = Dir[File.join(task.reviews_dir, "*-*.md")].filter_map do |path|
          File.basename(path).match(/-(\d{2})\.md\z/)&.[](1)&.to_i
        end
        max_pass = passes.max || 0
        bias = review_summary_triage_bias(task) || cfg&.dig("review", "triage", "bias") || "courageous"
        "Review passes: #{max_pass}\nTriage bias: #{bias}"
      end

      def review_summary_triage_bias(task)
        triage_path = Dir[File.join(task.reviews_dir, "triage-*.md")].sort.last
        if triage_path
          File.read(triage_path) =~ /^bias:\s*(\S+)/i and return Regexp.last_match(1)
        end
        nil
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
