require "time"
require "hive/babysitter/job_store"
require "hive/babysitter/pr_fixer"
require "hive/gh"
require "hive/task_journal"
require "hive/task_projection"

module Hive
  module Babysitter
    module JobRunner
      module_function

      HARD_CHECK_FAILURES = %w[
        ACTION_REQUIRED CANCELLED FAILURE STARTUP_FAILURE TIMED_OUT
      ].freeze
      READY_CONCLUSIONS = %w[NEUTRAL SKIPPED SUCCESS].freeze

      def run(job:, store:, project:, cfg:, dry_run:, logger:, inflight:, now: Time.now.utc,
              owner: default_owner)
        return :dry_run if dry_run

        lease_sec = [ cfg.dig("babysitter", "budget_minutes").to_i * 60 + 120, 300 ].max
        token = store.claim!(
          job.fetch("job_id"), owner: owner, now: now, lease_sec: lease_sec,
          claim_resolver: ->(_claim) { :resolved }, owner_pid: Process.pid
        )
        return :unclaimed unless token

        outcome = :active
        begin
          current = store.read(job.fetch("job_id"))
          snapshot = Hive::Gh.exact_pr_snapshot(current.fetch("pr_url"), cfg: cfg)
          validate_snapshot_identity!(current, snapshot)
          head_changed = snapshot.head_sha != current.fetch("head_sha")
          current = observe_head!(store, token, current, snapshot, now: now)
          projection = projection_for(current)

          outcome = case snapshot.state
          when "MERGED"
            append_lifecycle!(
              store, token, current, "merged", "explicit GitHub merged observation",
              observed_at: snapshot.observed_at,
              extra_payload: { "merged_at" => snapshot.merged_at },
              evidence: [ { "kind" => "github_pr_snapshot", "state" => "MERGED",
                            "observed_at" => snapshot.observed_at } ]
            )
            store.mark_terminal!(token, now: now)
            :merged
          when "CLOSED"
            append_blocker!(store, token, current, "closed_unmerged", true,
                            "GitHub reports CLOSED without merged_at", snapshot.observed_at)
            :needs_human
          when "OPEN"
            activate_if_needed!(store, token, current, projection, snapshot.observed_at)
            if head_changed
              :head_changed
            else
              assess_open!(store, token, current, snapshot, project, cfg, logger, inflight, now: now)
            end
          end
        rescue Hive::GhError => e
          current ||= store.read(job.fetch("job_id"))
          append_blocker!(store, token, current, "github_unavailable", false,
                          bounded_detail(e.message), now.utc.iso8601(6))
          logger&.event(:job_blocked, project: project["name"], job_id: job["job_id"],
                       reason: "github_unavailable")
          outcome = :blocked
        rescue Hive::Babysitter::JobStore::StaleClaim, Hive::TaskJournal::AttemptMismatch
          outcome = :stale_claim
        ensure
          begin
            store.release!(token, outcome: outcome, now: now)
          rescue Hive::Babysitter::JobStore::StaleClaim
            nil
          end
        end
        emit_operational(project, current || job, token, outcome)
        outcome
      end

      def assess_open!(store, token, job, snapshot, project, cfg, logger, inflight, now:)
        status = status_for(snapshot, project, cfg)
        return observe_rollup_head!(store, token, job, snapshot, status, cfg, now: now) if head_moved?(snapshot, status)
        return append_ready!(store, token, job, snapshot) if ready?(status)

        push_authorizer = lambda do
          store.authorize!(
            token, expected_sha: job.fetch("head_sha"), head_generation: job.fetch("head_generation"),
            finalize_attempt_id: job.fetch("finalize_attempt_id")
          )
          remote = Hive::Gh.exact_pr_snapshot(job.fetch("pr_url"), cfg: cfg)
          unless remote.state == "OPEN" && remote.head_sha == job.fetch("head_sha")
            raise Hive::Babysitter::JobStore::StaleClaim, "remote PR head moved before sanctioned push"
          end
          true
        end
        Hive::Babysitter::PrFixer.run(
          pr_hash(snapshot, status), project, cfg, dry_run: false, logger: logger,
          inflight: inflight, push_authorizer: push_authorizer
        )

        refreshed = Hive::Gh.exact_pr_snapshot(job.fetch("pr_url"), cfg: cfg)
        validate_snapshot_identity!(job, refreshed)
        if refreshed.head_sha != job.fetch("head_sha")
          observe_head!(store, token, job, refreshed, now: now)
          return :head_changed
        end
        return observe_terminal_refresh!(store, token, job, refreshed, now: now) unless refreshed.state == "OPEN"

        refreshed_status = status_for(refreshed, project, cfg)
        return observe_rollup_head!(store, token, job, refreshed, refreshed_status, cfg, now: now) if head_moved?(refreshed, refreshed_status)
        return append_ready!(store, token, job, refreshed) if ready?(refreshed_status)

        code, needs_human, detail = blocker_for(refreshed_status)
        append_blocker!(store, token, job, code, needs_human, detail, refreshed.observed_at)
        needs_human ? :needs_human : :blocked
      end

      def observe_terminal_refresh!(store, token, job, snapshot, now:)
        if snapshot.state == "MERGED"
          append_lifecycle!(store, token, job, "merged", "explicit GitHub merged observation",
                            observed_at: snapshot.observed_at,
                            extra_payload: { "merged_at" => snapshot.merged_at })
          store.mark_terminal!(token, now: now)
          :merged
        else
          append_blocker!(store, token, job, "closed_unmerged", true,
                          "GitHub reports CLOSED without merged_at", snapshot.observed_at)
          :needs_human
        end
      end

      def observe_rollup_head!(store, token, job, snapshot, _status, cfg, now:)
        refreshed = Hive::Gh.exact_pr_snapshot(job.fetch("pr_url"), cfg: cfg)
        validate_snapshot_identity!(job, refreshed)
        if refreshed.head_sha == job.fetch("head_sha")
          append_blocker!(store, token, job, "stale_status_snapshot", false,
                          "GitHub status did not describe the exact current head", snapshot.observed_at)
          return :blocked
        end

        observe_head!(store, token, job, refreshed, now: now)
        :head_changed
      end

      def observe_head!(store, token, job, snapshot, now:)
        return job if snapshot.head_sha == job.fetch("head_sha")

        generation = job.fetch("head_generation") + 1
        candidate = job.merge("head_sha" => snapshot.head_sha, "head_generation" => generation)
        append_lifecycle!(
          store, token, candidate, "head_superseded", "observed a new exact PR head",
          observed_at: snapshot.observed_at,
          extra_payload: { "previous_head_sha" => job.fetch("head_sha") },
          event_id: "#{job.fetch('job_id')}:head:#{generation}:#{snapshot.head_sha}"
        )
        store.advance_head!(
          token, previous_sha: job.fetch("head_sha"), head_sha: snapshot.head_sha,
          head_generation: generation, now: now
        )
      end

      def activate_if_needed!(store, token, job, projection, observed_at)
        return if %w[babysitter_active merge_ready].include?(projection.fetch("state"))

        append_lifecycle!(store, token, job, "babysitter_active", "claimed exact PR job",
                          observed_at: observed_at,
                          event_id: "#{job.fetch('job_id')}:active:#{token.fetch('claim_fence')}")
      end

      def append_ready!(store, token, job, snapshot)
        return :merge_ready if projection_for(job).fetch("state") == "merge_ready"

        append_lifecycle!(
          store, token, job, "merge_ready", "current exact PR head is merge ready",
          observed_at: snapshot.observed_at,
          event_id: "#{job.fetch('job_id')}:ready:#{job.fetch('head_generation')}:#{job.fetch('head_sha')}",
          evidence: [ { "kind" => "github_pr_status", "head_sha" => job.fetch("head_sha") } ]
        )
        :merge_ready
      end

      def append_blocker!(store, token, job, code, needs_human, detail, observed_at)
        append_lifecycle!(
          store, token, job, "babysitter_blocked", "exact PR watching is blocked",
          observed_at: observed_at,
          event_id: "#{job.fetch('job_id')}:blocked:#{token.fetch('claim_fence')}:#{code}",
          extra_payload: {
            "blocker" => {
              "code" => code, "needs_human" => needs_human,
              "detail" => bounded_detail(detail), "source" => "babysitter"
            }
          }
        )
      end

      def append_lifecycle!(store, token, job, event_type, reason, observed_at:, extra_payload: {},
                            evidence: [], event_id: nil)
        identity = job.fetch("identity")
        producer = {
          "kind" => "babysitter_job", "job_id" => job.fetch("job_id"),
          "claim_fence" => token.fetch("claim_fence"), "owner" => token.fetch("owner")
        }
        event_id ||= "#{job.fetch('job_id')}:#{event_type}:#{token.fetch('claim_fence')}"
        Hive::TaskJournal::Writer.new(
          task_folder: job.fetch("task_folder"), authority_validator: store
        ).append_once(
          event_id: event_id, event_type: event_type, occurred_at: observed_at,
          observed_at: observed_at,
          task: { "id" => identity.fetch("task_id").to_s, "slug" => identity.fetch("task_slug") },
          workflow: "coding", stage: File.basename(File.dirname(job.fetch("task_folder"))),
          attempt_id: job.fetch("finalize_attempt_id"),
          task_generation: identity.fetch("task_generation"),
          ownership_generation: "babysitter-job:#{job.fetch('job_id')}",
          reason: reason, producer: producer, evidence: evidence,
          provenance: { "source" => "hive-babysitter", "job_id" => job.fetch("job_id") },
          payload: coordinates(job).merge(extra_payload)
        )
      end

      def coordinates(job)
        identity = job.fetch("identity")
        {
          "job_id" => job.fetch("job_id"), "repository" => identity.fetch("repository"),
          "pr_number" => identity.fetch("pr_number"), "pr_url" => job.fetch("pr_url"),
          "head_sha" => job.fetch("head_sha"), "head_generation" => job.fetch("head_generation"),
          "finalize_attempt_id" => job.fetch("finalize_attempt_id")
        }
      end

      def projection_for(job)
        records = Hive::TaskProjection.read_journal(
          File.join(job.fetch("task_folder"), Hive::TaskJournal::JOURNAL_BASENAME)
        )
        Hive::Finalization::Projection.project(records: records)
      end

      def validate_snapshot_identity!(job, snapshot)
        identity = job.fetch("identity")
        return if snapshot.repository == identity.fetch("repository") &&
                  snapshot.number == identity.fetch("pr_number") && snapshot.url == job.fetch("pr_url")

        raise Hive::GhError, "exact PR snapshot does not match claimed job identity"
      end

      def head_moved?(snapshot, status)
        sha = status["headRefOid"].to_s.downcase
        !sha.empty? && sha != snapshot.head_sha
      end

      def status_for(snapshot, project, cfg)
        if !snapshot.mergeable.nil? && !snapshot.merge_state_status.nil? &&
           !snapshot.status_check_rollup.nil?
          return {
            "mergeable" => snapshot.mergeable,
            "mergeStateStatus" => snapshot.merge_state_status,
            "reviewDecision" => snapshot.review_decision,
            "statusCheckRollup" => snapshot.status_check_rollup,
            "headRefOid" => snapshot.head_sha,
            "url" => snapshot.url
          }
        end

        Hive::Gh.pr_status_rollup(project.fetch("path"), snapshot.number, cfg: cfg)
      end

      def ready?(status)
        return false unless status["mergeable"].to_s.upcase == "MERGEABLE"
        return false unless status["mergeStateStatus"].to_s.upcase == "CLEAN"
        return false unless [ "", "APPROVED" ].include?(status["reviewDecision"].to_s.upcase)

        ready_checks?(Array(status["statusCheckRollup"]))
      end

      def blocker_for(status)
        review = status["reviewDecision"].to_s.upcase
        return [ "review_required", true, "Current head still requires review" ] if %w[CHANGES_REQUESTED REVIEW_REQUIRED].include?(review)

        checks = Array(status["statusCheckRollup"])
        conclusions = checks.filter_map { |check| check["conclusion"].to_s.upcase if check.is_a?(Hash) }
        if (conclusions & HARD_CHECK_FAILURES).any?
          return [ "checks_failed", true, "One or more checks failed on the current head" ]
        end
        return [ "checks_pending", false, "Checks are still pending on the current head" ] unless ready_checks?(checks)

        [ "mergeability_blocked", true, "Current head is not cleanly mergeable" ]
      end

      def ready_checks?(checks)
        checks.all? do |check|
          check.is_a?(Hash) && READY_CONCLUSIONS.include?(check["conclusion"].to_s.upcase)
        end
      end

      def pr_hash(snapshot, status)
        {
          "number" => snapshot.number, "url" => snapshot.url,
          "headRefName" => snapshot.head_branch, "baseRefName" => snapshot.base_branch,
          "headRefOid" => snapshot.head_sha, "mergeStateStatus" => status["mergeStateStatus"],
          "labels" => [], "isDraft" => false, "isCrossRepository" => false
        }
      end

      def bounded_detail(value)
        value.to_s.gsub(/\s+/, " ")[0, 300]
      end

      def default_owner
        "hive-babysitter:#{Process.pid}"
      end

      def emit_operational(project, job, token, outcome)
        action, event_outcome = case outcome
        when :merge_ready then [ "readiness", "ready" ]
        when :merged then [ "merged", "merged" ]
        when :head_changed then [ "head-change", "success" ]
        when :needs_human then [ "blocked", "needs_human" ]
        when :blocked then [ "blocked", "unavailable" ]
        when :stale_claim then [ "job-claim", "stale_claim" ]
        else [ "exact-pr", "active" ]
        end
        Hive::Babysitter::Events.emit(
          project: project, pr: job.dig("identity", "pr_number"), action: action,
          outcome: event_outcome, job_id: job["job_id"], claim_fence: token["claim_fence"],
          head_sha: job["head_sha"], head_generation: job["head_generation"]
        )
      rescue StandardError
        nil
      end
    end
  end
end
