require "digest"
require "shellwords"
require "time"
require "yaml"
require "hive/execute_waiting_action"
require "hive/markers"
require "hive/secret_patterns"
require "hive/diagnostic_helpers"

module Hive
  class TaskAction
    # Builds the red-status diagnostic payload for a (Task, Marker) pair:
    # the summary/detail an operator reads, the on-disk artifact paths
    # backing it, and the suggested next action. Surfaced by `hive status
    # --json`, the TUI's red-status detail view, the bot, and the daemon.
    #
    # Constructed by `TaskAction` with the classification context the
    # diagnostic depends on (the action `key`, the rerun `command`, and the
    # handful of state predicates that also drive classification) so this
    # object stays a pure function of its inputs and never reaches back into
    # the classifier.
    class Diagnostic
      # Caps shared with Hive::DiagnosticEvidence via Hive::DiagnosticHelpers so
      # the two diagnose surfaces can't drift (SUMMARY_MAX is schema-pinned).
      SUMMARY_MAX = Hive::DiagnosticHelpers::SUMMARY_MAX
      DETAIL_MAX = 4_000
      # The schema pins artifact_paths maxItems=20; this is the producer-side
      # enforcement so a marker with hundreds of matching artifacts (legacy
      # reviews/ dirs) cannot blow past the contract.
      ARTIFACT_PATHS_MAX = 20
      # Cap on .log files probed per task per status invocation. Bounds the
      # File.mtime cost when a task accumulated many agent-run logs over a
      # long-lived branch (saw 50+ on auto-rebase test fixtures).
      LOG_GLOB_CAP = Hive::DiagnosticHelpers::LOG_GLOB_CAP
      # Real frontmatter is < 1KB; 16KB is generous for human-written
      # artifacts and tight enough to reject a runaway file masquerading as
      # frontmatter.
      FRONTMATTER_SCAN_BYTES = Hive::DiagnosticHelpers::FRONTMATTER_SCAN_BYTES

      AUTO_COMMIT_MANUAL_FAILURE_REASONS = %w[
        fix_auto_commit_scope_failed
        fix_auto_commit_sign_policy_failed
        fix_auto_commit_signing_failed
      ].freeze
      FIX_STATUS_CHECK_MANUAL_FAILURE_REASON = "fix_status_check_failed".freeze

      def initialize(task:, marker:, action_key:, rerun_command:,
                     incomplete_plan_artifact:, finalize_missing_pr_md:,
                     finalize_missing_pr_url:, finalize_pr_url_mismatch:,
                     legacy_execute_findings:, stale_agent_reason:,
                     state_file_mtime: nil,
                     project_name: nil, project_count: 1)
        @task = task
        @marker = marker
        @action_key = action_key
        @rerun_command = rerun_command
        @incomplete_plan_artifact = incomplete_plan_artifact
        @finalize_missing_pr_md = finalize_missing_pr_md
        @finalize_missing_pr_url = finalize_missing_pr_url
        @finalize_pr_url_mismatch = finalize_pr_url_mismatch
        @legacy_execute_findings = legacy_execute_findings
        @stale_agent_reason = stale_agent_reason
        @state_file_mtime = state_file_mtime
        @project_name = project_name
        @project_count = project_count
      end

      def to_h
        synthesized = synthetic_stale_agent_diagnostic
        return synthesized if synthesized
        return nil unless diagnostic_action?

        artifacts = diagnostic_artifacts.select { |path| safe_diagnostic_artifact?(path) }
        primary = incomplete_plan_artifact? ? nil : artifacts.first
        updated_at = diagnostic_updated_at(primary)
        detail = primary ? artifact_detail(primary) : marker_detail

        {
          "summary" => truncate(redact(marker_summary), SUMMARY_MAX),
          "detail" => truncate(redact(detail), DETAIL_MAX),
          "source" => primary ? "artifact" : "marker",
          "source_path" => primary,
          "artifact_paths" => artifacts.uniq.first(ARTIFACT_PATHS_MAX),
          "generated_by" => diagnostic_generated_by(primary),
          "marker_signature" => marker_signature,
          "suggested_next_action" => suggested_next_action_payload,
          "updated_at" => updated_at.utc.iso8601
        }
      end

      def next_action
        return nil unless execute_waiting_input?

        Hive::ExecuteWaitingAction.build(task, marker, rerun_with: rerun_command)
      end

      private

      attr_reader :task, :marker, :rerun_command

      # Synthesized purely from liveness signal — the on-disk marker is still
      # AGENT_WORKING (no artifact, no diagnosis pass), so the normal
      # diagnostic_artifacts pipeline has nothing to chew on. Once the
      # daemon's StaleAgentHealer rewrites the marker to ERROR reason=..., the
      # generic_error_artifacts path takes over and this shape is no longer
      # produced.
      def synthetic_stale_agent_diagnostic
        reason = @stale_agent_reason
        return nil unless reason

        {
          "summary" => stale_agent_summary(reason),
          "detail" => "AGENT_WORKING marker is stale. The daemon's StaleAgentHealer will rewrite it to ERROR reason=#{reason} on its next tick (typically within 30 seconds). Once healed, re-read `hive status --json` or use the standard red-status flow, then run the reported suggested_next_action.command so the current ERROR marker guard is included. If the daemon is not running, start it with `systemctl --user start hive-daemon` (or your platform equivalent).",
          "source" => "marker",
          "source_path" => nil,
          "artifact_paths" => [],
          "generated_by" => "local",
          "marker_signature" => marker_signature,
          "suggested_next_action" => suggested_next_action_payload,
          "updated_at" => Time.now.utc.iso8601
        }
      end

      def stale_agent_summary(reason)
        case reason
        when :agent_died
          recorded_pid = marker.attrs["pid"]
          if recorded_pid && !recorded_pid.empty?
            "agent process not alive (recorded pid=#{recorded_pid})"
          else
            "agent process not alive"
          end
        when :agent_orphaned
          age_min = ((Time.now - @state_file_mtime) / 60).to_i
          "agent never attached (marker placeholder is #{age_min} min old)"
        end
      end

      # The diagnostic shape exists for ALL three recovery action keys per
      # ADR-027 and wiki/commands/status.md — recover_review, error, AND
      # recover_execute (EXECUTE_STALE). The TUI's red_status_detail view
      # renders all three under a unified [Enter] Recover / [o] Open in agent
      # contract; recover_execute rows surface the Risk-#3 mitigation flash
      # when [Enter] Recover is pressed (no auto-retry recipe), then the
      # screen closes. Bot, daemon, and external `--json` consumers also rely
      # on this field for EXECUTE_STALE rows the autofix path cannot resolve;
      # emitting nil would defeat the diagnose-then-act feature for one of the
      # three red states it covers.
      def diagnostic_action?
        %w[recover_execute recover_review error].include?(@action_key.to_s)
      end

      def diagnostic_artifacts
        return latest_log_artifacts if incomplete_plan_artifact?
        return fresh_diagnosis_artifact + execute_stale_artifacts if legacy_execute_findings?

        case marker.name
        when :review_error
          fresh_diagnosis_artifact + review_error_artifacts
        when :review_ci_stale
          fresh_diagnosis_artifact + review_ci_artifacts
        when :review_stale
          fresh_diagnosis_artifact + review_stale_artifacts
        when :execute_stale
          fresh_diagnosis_artifact + execute_stale_artifacts
        when :error
          fresh_diagnosis_artifact + generic_error_artifacts
        else
          []
        end
      end

      def fresh_diagnosis_artifact
        path = task_artifact("diagnostics", "red-status.md")
        return [] unless File.exist?(path)
        return [] unless safe_diagnostic_artifact?(path)

        metadata = diagnostic_frontmatter(path)
        return [] unless trusted_diagnostic_generator?(metadata["generated_by"])
        return [] unless metadata["marker_signature"].to_s == marker_signature
        # marker_signature is SHA-256(marker_name + sorted_attr_pairs), so a
        # red → green → same-shape red rotation cycle produces an identical
        # signature across episodes. Without an ordering check the second
        # episode would silently reuse the first's artifact. Compare mtimes:
        # the state_file is touched on every marker rotation, so an artifact
        # older than the state_file is from a previous episode. See #89.
        return [] if artifact_predates_marker?(path)

        [ path ]
      end

      def artifact_predates_marker?(artifact_path)
        artifact_mtime = safe_mtime(artifact_path)
        state_mtime = safe_mtime(task.state_file)
        return false if artifact_mtime.nil? || state_mtime.nil?

        artifact_mtime < state_mtime
      end

      def review_error_artifacts
        pass = pass_suffix
        phase = marker.attrs["phase"].to_s
        reason = marker.attrs["reason"].to_s
        paths = []
        paths.concat(paths_from_marker_files)
        paths << task_artifact("reviews", "errors-#{pass}.md") if pass
        paths << task_artifact("reviews", "fix-guardrail-#{pass}.md") if pass && reason == "fix_guardrail"
        paths << task_artifact("reviews", "escalations-#{pass}.md") if pass
        paths.concat(review_phase_logs(phase, pass))
        paths.concat(latest_log_artifacts)
        paths
      end

      def review_ci_artifacts
        [
          task_artifact("reviews", "ci-blocked.md"),
          *glob_task_artifacts("logs", "review-ci-fix-attempt*.log"),
          *latest_log_artifacts
        ]
      end

      def review_stale_artifacts
        pass = pass_suffix
        paths = []
        paths << task_artifact("reviews", "escalations-#{pass}.md") if pass
        paths.concat(glob_task_artifacts("reviews", "*-#{pass}.md")) if pass
        paths.concat(latest_log_artifacts)
        paths
      end

      # The previous-pass review files (the user needs to inspect findings the
      # agent could not satisfy) plus the last few agent logs. Cap the
      # review-md glob at the most recent entries by filename so a long-lived
      # task with dozens of review files doesn't blow past the schema's
      # artifact_paths maxItems.
      def execute_stale_artifacts
        review_md = glob_task_artifacts("reviews", "*.md").sort.last(3)
        [ *review_md, *latest_log_artifacts ]
      end

      def generic_error_artifacts
        [ *latest_log_artifacts, task.state_file ]
      end

      def review_phase_logs(phase, pass)
        return [] unless pass

        case phase
        when "fix"
          glob_task_artifacts("logs", "review-fix-pass#{pass}*.log")
        when "triage"
          glob_task_artifacts("logs", "review-triage-pass#{pass}*.log")
        when "browser"
          glob_task_artifacts("logs", "review-browser-pass#{pass}*.log")
        when "reviewers"
          glob_task_artifacts("logs", "review-*-pass#{pass}*.log")
        else
          []
        end
      end

      def paths_from_marker_files
        marker.attrs.fetch("files", "").to_s.split(/[,\s]+/).filter_map do |relative|
          next if relative.empty? || relative.include?("..") || relative.start_with?("/")

          File.join(task.folder, relative)
        end
      end

      # Cap the candidate set (LOG_GLOB_CAP) before sorting by mtime so a
      # long-lived task with 100+ retained logs doesn't pay an O(N) stat sweep
      # on every status poll. The cap is the most recent N by filename-suffix
      # timestamp (hive's log filenames embed an ISO timestamp), a good proxy
      # for mtime ordering that avoids the stat. The final sort-by-mtime over
      # the capped set still produces the freshest 3.
      def latest_log_artifacts
        candidates = log_dirs.flat_map { |dir| Dir[File.join(dir, "*.log")] }
        return [] if candidates.empty?

        head = candidates.sort.last(LOG_GLOB_CAP)
        head.sort_by { |path| safe_mtime(path) || Time.at(0) }.last(3).reverse
      end

      # Shared with the classifier so the artifact-root check can't drift from it.
      def log_dirs = Hive::TaskAction.log_dirs(task)

      def glob_task_artifacts(*parts)
        Dir[task_artifact(*parts)]
      end

      def task_artifact(*parts)
        File.join(task.folder, *parts)
      end

      def pass_suffix
        raw = marker.attrs["pass"].to_s
        return nil unless raw.match?(/\A[1-9]\d*\z/)

        format("%02d", raw.to_i)
      end

      def marker_summary
        return "PLAN_MISSING_OUTPUT" if incomplete_plan_artifact?
        return "FINALIZE_MISSING_PR_MD" if finalize_missing_pr_md?
        return "FINALIZE_MISSING_PR_URL" if finalize_missing_pr_url?
        return "FINALIZE_PR_URL_MISMATCH" if finalize_pr_url_mismatch?

        # The synthetic prefixes above are this surface's own; everything else
        # is the shared NAME+attrs rendering (plan R-5). Diagnostic only reaches
        # here for red markers, never :none, so the nil case can't occur — but
        # that invariant is derived (enforced upstream by diagnostic_action?),
        # not local: if a future widening of diagnostic_action? ever let :none
        # through, Markers.summary(:none)→nil degrades to a *silent empty*
        # summary (redact(nil)→""), not the old visible "NONE" and not a crash.
        Hive::Markers.summary(marker)
      end

      def marker_detail
        if incomplete_plan_artifact?
          return [
            "PLAN_MISSING_OUTPUT",
            "Plan is incomplete because #{task.state_file} is missing or empty.",
            "Rerun the plan stage to regenerate plan.md."
          ].join("\n")
        end

        if finalize_missing_pr_md?
          return [
            "FINALIZE_MISSING_PR_MD",
            "Finalize cannot run because #{task.state_file} is missing.",
            "Move the task back to 5-open-pr or recreate pr.md with pr_url frontmatter."
          ].join("\n")
        end

        if finalize_missing_pr_url?
          return [
            "FINALIZE_MISSING_PR_URL",
            "Finalize cannot archive because #{task.state_file} is missing pr_url metadata.",
            "Repair pr.md or move the task back to 5-open-pr so the PR metadata can be recreated."
          ].join("\n")
        end

        if finalize_pr_url_mismatch?
          return [
            "FINALIZE_PR_URL_MISMATCH",
            "Finalize cannot archive because the COMPLETE marker pr_url does not match pr.md frontmatter.",
            "Rerun finalize or repair pr.md so both PR URLs match."
          ].join("\n")
        end

        if auto_commit_scope_failure?
          return [
            marker_summary,
            "Hive rejected the fix-agent fallback commit because staged paths were outside review.fix.auto_commit.scope_check.",
            "Inspect the listed files, remove or revert rejected worktree changes, or adjust review.fix.auto_commit.scope_check before clearing REVIEW_ERROR."
          ].join("\n")
        end

        if auto_commit_signing_failure?
          return [
            marker_summary,
            "Hive could not create the fix-agent fallback commit because commit signing policy or signing execution blocked it.",
            "Inspect the worktree changes, manually commit or revert remaining changes, fix signing config or set review.fix.auto_commit.sign_policy to inherit/bypass/fail as appropriate, then clear REVIEW_ERROR and re-run."
          ].join("\n")
        end

        if fix_status_check_failure?
          return [
            marker_summary,
            "Hive could not read the task worktree Git status before or after running the review fix agent.",
            "Repair the worktree or repository state, then clear REVIEW_ERROR and re-run the review."
          ].join("\n")
        end

        [ marker_summary, "No diagnostic artifact was found under #{task.folder}." ].join("\n")
      end

      def artifact_detail(path)
        "#{path}:\n#{tail_file(path)}"
      rescue SystemCallError => e
        "#{path}: #{e.class}: #{e.message}"
      end

      # Boundary-safe UTF-8 tail; shared with Hive::DiagnosticEvidence so both
      # surfaces redact a secret split across the tail window identically.
      def tail_file(path) = Hive::DiagnosticHelpers.tail_file(path)

      def diagnostic_updated_at(primary)
        safe_mtime(primary) || safe_mtime(task.state_file) || Time.now
      end

      def diagnostic_generated_by(primary)
        return "local" unless primary && File.basename(primary) == "red-status.md"

        diagnostic_frontmatter(primary)["generated_by"].to_s.tap do |value|
          return value unless value.empty?
        end
        "local"
      end

      # Scan up to FRONTMATTER_SCAN_BYTES of the artifact head looking for the
      # closing `---` boundary. A fixed 4KB head used to silently parse
      # frontmatter blocks larger than 4KB as empty (no closing match);
      # widening the window to 16KB keeps the cost bounded while accepting
      # real-world artifact frontmatter.
      def diagnostic_frontmatter(path)
        body = File.read(path, FRONTMATTER_SCAN_BYTES)
        match = body.match(/\A---\n(.*?)\n---\n/m)
        return {} unless match

        parsed = YAML.safe_load(match[1], permitted_classes: [ Time ]) || {}
        parsed.is_a?(Hash) ? parsed.transform_keys(&:to_s) : {}
      rescue Psych::Exception, SystemCallError
        {}
      end

      def trusted_diagnostic_generator?(name)
        Hive::Schemas::DIAGNOSTIC_GENERATORS.include?(name.to_s)
      end

      def marker_signature
        Hive::TaskAction.marker_signature(marker)
      end

      # Recovery hint surfaced inside the diagnostic JSON so agents and
      # external consumers don't have to re-derive the next move from marker
      # shape alone. `kind` mirrors the operator gesture:
      #   - "retry" — Enter-in-detail-view runs the existing recover_review /
      #     recover_error path, or a markerless synthetic-error direct rerun
      #     such as PLAN_MISSING_OUTPUT; `command` is the copy-paste shell form.
      #   - "manual_fix" — max_passes-hit REVIEW_STALE; the operator must edit
      #     `reviews/escalations-NN.md` before retry. command stays null
      #     because there's nothing safe to dispatch.
      #   - "clear_marker" — reserved for future expansion; not yet emitted
      #     because the in-tree heuristics route everything else through retry
      #     or manual_fix.
      def suggested_next_action_payload
        return nil unless diagnostic_action?

        return { "kind" => "retry", "command" => workflow_command("plan") } if incomplete_plan_artifact?

        return manual_fix if finalize_missing_pr_md? || finalize_missing_metadata_error?
        return manual_fix if finalize_missing_pr_url? || finalize_pr_url_mismatch?
        return manual_fix if max_passes_review_stale_with_escalations?

        # EXECUTE_STALE rows have no auto-retry recipe: the operator must
        # review findings and either edit the worktree or lower the pass
        # counter. Emit manual_fix with command:null instead of falling
        # through to a nil payload so agents reading hive-status JSON see an
        # explicit "do not auto-retry" signal rather than the absence of data.
        # See PR #84 review finding #9.
        return manual_fix if marker.name == :execute_stale || legacy_execute_findings?
        return manual_fix if fix_status_check_failure?
        return manual_fix if auto_commit_manual_failure?

        # CleanExit's `ensure_clean_on_exit_failed` is operator-resolves-the-
        # worktree territory: scope-violating or signing-failed residue needs
        # human inspection. Emit `manual_fix` with `command:null` so polling
        # agents see the explicit "do not auto-retry" signal (the bot's
        # manual-only routing in `RecoverySequence` already refuses to dispatch
        # a retry verb for this reason; the JSON payload mirrors that decision
        # so CLI-driven consumers don't try to construct one themselves).
        return manual_fix if clean_exit_manual_failure?

        cmd = retry_command_string or return nil

        { "kind" => "retry", "command" => cmd }
      end

      def manual_fix
        { "kind" => "manual_fix", "command" => nil }
      end

      def max_passes_review_stale_with_escalations?
        Hive::TaskAction.max_passes_review_stale_with_escalations?(
          folder: task.folder, marker_name: marker.name, attrs: marker.attrs
        )
      end

      # `hive markers clear` accepts --match-attr KEY=VALUE or comma-separated
      # KEY=VALUE pairs; pick the most-identifying guard per marker shape. The
      # recipe stays a copy-pasteable one-liner so external agents and humans
      # can run it from a shell unchanged.
      def retry_command_string
        attrs = marker.attrs || {}
        case marker.name
        when :review_error, :review_ci_stale
          attr_pair = priority_match_attr(attrs, %w[pass phase reason])
          clear_argv = [ "hive", "markers", "clear", task.folder,
                         "--name", marker.name.to_s.upcase, *attr_pair ]
          "#{clear_argv.shelljoin} && #{[ 'hive', 'run', task.folder ].shelljoin}"
        when :review_stale
          attr_pair = priority_match_attr(attrs, %w[pass reason])
          clear_argv = [ "hive", "markers", "clear", task.folder,
                         "--name", "REVIEW_STALE", *attr_pair ]
          "#{clear_argv.shelljoin} && #{[ 'hive', 'run', task.folder ].shelljoin}"
        when :error
          match_attr = Hive::Markers.error_recovery_match_attr(attrs)
          attr_pair = match_attr ? [ "--match-attr", match_attr ] : []
          clear_argv = [ "hive", "markers", "clear", task.folder,
                         "--name", "ERROR", *attr_pair ]
          "#{clear_argv.shelljoin} && #{[ 'hive', 'run', task.folder ].shelljoin}"
        end
      end

      def priority_match_attr(attrs, keys)
        keys.each do |key|
          value = attrs[key]
          return [ "--match-attr", "#{key}=#{value}" ] if value && !value.to_s.empty?
        end
        []
      end

      def workflow_command(verb)
        parts = [ "hive", verb, task.slug ]
        parts.concat([ "--project", @project_name ]) if @project_name && @project_count > 1
        parts.concat([ "--from", stage_dir ])
        parts.shelljoin
      end

      def stage_dir
        "#{task.stage_index}-#{task.stage_name}"
      end

      def safe_mtime(path) = Hive::DiagnosticHelpers.safe_mtime(path)

      def safe_diagnostic_artifact?(path)
        return false if path.nil? || path.to_s.empty? || !File.file?(path)

        real = File.realpath(path)
        diagnostic_roots.any? { |root| path_inside?(real, root) }
      rescue Errno::ENOENT
        false
      rescue SystemCallError => e
        # EACCES / ELOOP / ENAMETOOLONG / EIO: the artifact may exist but we
        # cannot determine its realpath. Returning false silently invisibles a
        # paid-for agent verdict (operator sees "no diagnostic available" while
        # the file exists). Surface via $stderr so support threads have a
        # breadcrumb; still return false so the local-marker fallback wins and
        # the snapshot does not crash.
        warn "[diagnose] cannot realpath #{path}: #{e.class}: #{e.message}"
        false
      end

      def diagnostic_roots
        # task.folder + any log_dirs are the legitimate roots an artifact may
        # live under. We deliberately do NOT add a project_root containment
        # filter: when .hive-state is a symlink to a separate volume (a
        # legitimate deployment pattern), task.folder.realpath lands outside
        # project_root.realpath and every diagnostic gets silently dropped. The
        # symlink-escape guard is already provided by checking that the
        # artifact's realpath is inside the (also realpath'd) task.folder /
        # log_dir, and realpath_or_expand rejects a root *directory* that is
        # itself a symlink so a `logs -> /outside` dir symlink can't enter the
        # trusted set in the first place.
        ([ task.folder ] + log_dirs).filter_map { |root| realpath_or_expand(root) }.uniq
      end

      def realpath_or_expand(path)
        return nil if path.nil? || path.to_s.empty?
        # Reject a root whose own leaf is a symlink: a symlinked evidence dir
        # (e.g. `logs -> /outside`) would otherwise resolve into a TRUSTED root
        # and let safe_diagnostic_artifact? approve every file under the target.
        # A symlinked *ancestor* (the legit `.hive-state -> /vol` case above)
        # still resolves normally because File.symlink? checks only the leaf.
        return nil if File.symlink?(path)

        File.realpath(path)
      rescue Errno::ENOENT
        File.expand_path(path)
      end

      def path_inside?(path, root)
        path == root || path.start_with?(root + File::SEPARATOR)
      end

      def redact(text)
        Hive::SecretPatterns.redact(text)
      end

      def truncate(text, max) = Hive::DiagnosticHelpers.truncate(text, max)

      def execute_waiting_input?
        task.stage_name == "execute" &&
          marker.name == :execute_waiting &&
          !legacy_execute_findings?
      end

      def auto_commit_scope_failure?
        marker.name == :review_error && marker.attrs["reason"].to_s == "fix_auto_commit_scope_failed"
      end

      def auto_commit_signing_failure?
        marker.name == :review_error && %w[
          fix_auto_commit_sign_policy_failed
          fix_auto_commit_signing_failed
        ].include?(marker.attrs["reason"].to_s)
      end

      def auto_commit_manual_failure?
        marker.name == :review_error && AUTO_COMMIT_MANUAL_FAILURE_REASONS.include?(marker.attrs["reason"].to_s)
      end

      def fix_status_check_failure?
        marker.name == :review_error &&
          marker.attrs["reason"].to_s == FIX_STATUS_CHECK_MANUAL_FAILURE_REASON
      end

      # `:error reason=ensure_clean_on_exit_failed` is the CleanExit invariant
      # refusing to auto-commit residue: either the staged paths fell outside
      # `review.fix.auto_commit.scope_check`, or `git add` / `git commit` /
      # `git status` failed or timed out. Operator must inspect the worktree
      # before any retry; there is no safe automated command to dispatch.
      def clean_exit_manual_failure?
        marker.name == :error && marker.attrs["reason"].to_s == "ensure_clean_on_exit_failed"
      end

      def finalize_missing_metadata_error?
        task.stage_name == "finalize" &&
          marker.name == :error &&
          %w[missing_pr_md missing_pr_url].include?(marker.attrs["reason"].to_s)
      end

      # The five state predicates below also drive action classification;
      # TaskAction computes them once and passes the result in so this object
      # and the classifier can never disagree about a (task, marker) pair.
      def incomplete_plan_artifact? = @incomplete_plan_artifact
      def finalize_missing_pr_md? = @finalize_missing_pr_md
      def finalize_missing_pr_url? = @finalize_missing_pr_url
      def finalize_pr_url_mismatch? = @finalize_pr_url_mismatch
      def legacy_execute_findings? = @legacy_execute_findings
    end
  end
end
