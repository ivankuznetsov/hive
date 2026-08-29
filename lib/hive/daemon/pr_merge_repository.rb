require "digest"
require "json"
require "time"
require "hive/runtime_control_plane"

module Hive
  module Daemon
    # Row-oriented persistence for pull-request reconciliation. Workflow files
    # remain authoritative; each SQL row is one bounded, restartable candidate.
    class PrMergeRepository
      MAX_DIAGNOSTIC_BYTES = 500
      MAX_EVIDENCE_BYTES = 64 * 1024
      DEFAULT_BACKOFF_BASE_SEC = 60
      DEFAULT_BACKOFF_MAX_SEC = 3600
      TERMINAL_RETENTION_SEC = 7 * 24 * 60 * 60
      REMOTE_POLL_HOLD_REASONS = %w[observed_head_changed].freeze
      TERMINAL_REMOTE_STATES = %w[merged delivered_elsewhere ambiguous].freeze

      class Invalid < Hive::Error; end

      def initialize(database: nil, dry_run: false, backoff_base_sec: DEFAULT_BACKOFF_BASE_SEC,
                     backoff_max_sec: DEFAULT_BACKOFF_MAX_SEC)
        @database = database
        @dry_run = dry_run
        @candidates = Hash.new { |hash, key| hash[key] = {} }
        @project_state = {}
        @backoff_base_sec = positive_number(backoff_base_sec, "backoff base")
        @backoff_max_sec = positive_number(backoff_max_sec, "backoff maximum")
        raise ArgumentError, "PR merge backoff maximum cannot be below its base" if
          @backoff_max_sec < @backoff_base_sec
      end

      def candidate_key(project:, slug:, task_generation:, pull_request:)
        Digest::SHA256.hexdigest(JSON.generate([
          project.to_s, slug.to_s, task_generation.to_s,
          *%w[url host repository number observed_head].map { |field| pull_request[field] }
        ]))
      end

      def outcome_key(project:, slug:, task_generation:)
        Digest::SHA256.hexdigest(JSON.generate([ project.to_s, slug.to_s, task_generation.to_s ]))
      end

      def candidates(identity)
        if @dry_run
          deep_copy(@candidates[memory_key(identity)].values)
        else
          database.read do |db|
            project_id = project_id!(db, identity)
            db[:pr_merge_reconciliations].where(project_id: project_id)
              .order(:reconciliation_id).map { |row| decode_candidate(row) }
          end
        end
      rescue RuntimeControlPlane::Error, Sequel::Error, KeyError => error
        raise Invalid, "cannot read PR merge reconciliation: #{error.message}"
      end

      def upsert_candidate(identity, candidate, now: Time.now.utc)
        validate_candidate!(candidate)
        prune_before = (now - TERMINAL_RETENTION_SEC).utc.iso8601(6)
        if @dry_run
          memory = @candidates[memory_key(identity)]
          memory.delete_if do |_key, item|
            terminal?(item) && item.fetch("updated_at") < prune_before
          end
          revision = memory.dig(candidate.fetch("key"), "_revision").to_i + 1
          memory[candidate.fetch("key")] = deep_copy(candidate).merge("_revision" => revision)
          return candidate
        end
        database.transaction do |db|
          project = project!(db, identity)
          db[:pr_merge_reconciliations].where(project_id: project.fetch(:project_id))
            .exclude(completed_at: nil).where { completed_at < prune_before }.delete
          row = row_for(db, project, identity, candidate, revision: 0)
          db[:pr_merge_reconciliations].insert_conflict(
            target: :reconciliation_id,
            update: row.except(:reconciliation_id, :revision).merge(
              revision: Sequel[:revision] + 1
            )
          ).insert(row)
        end
        candidate
      rescue RuntimeControlPlane::Error, Sequel::Error, KeyError => error
        raise Invalid, "cannot persist PR merge candidate: #{error.message}"
      end

      def checkpoint(identity, candidate, expected_task_generation:, now: Time.now.utc)
        validate_candidate!(candidate)
        candidate = deep_copy(candidate)
        candidate["updated_at"] = now.utc.iso8601(6)
        if @dry_run
          current = @candidates[memory_key(identity)][candidate.fetch("key")]
          verify_generation!(current, expected_task_generation)
          expected_revision = Integer(candidate.fetch("_revision"))
          raise Hive::ConcurrentRunError, "merge reconciliation candidate changed" unless
            current.fetch("_revision") == expected_revision
          candidate["_revision"] = expected_revision + 1
          @candidates[memory_key(identity)][candidate.fetch("key")] = candidate
          return candidate
        end
        database.transaction do |db|
          project = project!(db, identity)
          expected_task_id = task_id_for(db, project, candidate)
          dataset = db[:pr_merge_reconciliations].where(
            reconciliation_id: candidate.fetch("key"), project_id: project.fetch(:project_id),
            task_id: expected_task_id,
            task_generation: expected_task_generation,
            revision: Integer(candidate.fetch("_revision"))
          )
          current = dataset.first
          verify_generation!(current && decode_candidate(current), expected_task_generation)
          changed = dataset.update(
            row_for(
              db, project, identity, candidate,
              revision: Integer(candidate.fetch("_revision")) + 1
            ).except(:reconciliation_id)
          )
          raise Hive::ConcurrentRunError, "merge reconciliation candidate changed" unless changed == 1
          candidate["_revision"] = Integer(candidate.fetch("_revision")) + 1
        end
        candidate
      rescue RuntimeControlPlane::Error, Sequel::Error, KeyError => error
        raise Invalid, "cannot checkpoint PR merge candidate: #{error.message}"
      end

      def next_candidate(identity, now: Time.now.utc)
        if @dry_run
          available = candidates(identity).reject do |candidate|
            terminal?(candidate) || held_without_poll?(candidate) ||
              future_retry?(candidate, now)
          end
          return nil if available.empty?

          keys = available.map { |candidate| candidate.fetch("key") }.sort
          cursor = project_state(identity).fetch("cursor", nil)
          selected_key = keys.rotate(
            cursor && keys.include?(cursor) ? keys.index(cursor) + 1 : 0
          ).first
          return available.find { |candidate| candidate.fetch("key") == selected_key }
        end

        database.read do |db|
          project_id = project_id!(db, identity)
          dataset = eligible_candidates(db, project_id, now)
          cursor = db[:pr_merge_project_state].where(project_id: project_id).get(:cursor)
          row = dataset.where { reconciliation_id > cursor }.first if cursor
          row ||= dataset.first
          row && decode_candidate(row)
        end
      end

      def advance_cursor(identity, key, now: Time.now.utc)
        state = project_state(identity)
        write_project_state(identity, state.merge("cursor" => key), now: now)
      end

      def backlog(identity)
        project_state(identity).fetch("backlog", empty_backlog(Time.at(0).utc))
      end

      def update_backlog(identity, outcomes:, now: Time.now.utc)
        value = {
          "watermark" => backlog(identity)["watermark"] || now.utc.iso8601(6),
          "scanned_at" => now.utc.iso8601(6), "complete" => true,
          "outcomes" => outcomes.to_h { |outcome| [ outcome.fetch("key"), outcome ] }
        }
        bounded_json(value, "PR merge backlog")
        write_project_state(identity, project_state(identity).merge("backlog" => value), now: now)
        value
      end

      def remote_poll_hold_reason?(reason) = REMOTE_POLL_HOLD_REASONS.include?(reason)

      def retry_after_failure(candidate, error, now: Time.now.utc)
        candidate = deep_copy(candidate)
        failures = candidate.dig("retry", "failures").to_i + 1
        delay = [ @backoff_base_sec * (2**[ failures - 1, 20 ].min), @backoff_max_sec ].min
        message = "#{error.class}: #{error.message}"[0, MAX_DIAGNOSTIC_BYTES]
        candidate["retry"] = {
          "failures" => failures, "not_before" => (now + delay).utc.iso8601(6)
        }
        candidate["archive"].merge!("status" => "failed", "last_error" => message)
        [ candidate, message ]
      end

      private

      def database
        @database ||= RuntimeControlPlane::Database.new(
          path: Hive::Paths.runtime_control_plane_path
        ).open!
      end

      def project_state(identity)
        if @dry_run
          return deep_copy(@project_state.fetch(memory_key(identity), {
            "cursor" => nil, "backlog" => empty_backlog(Time.at(0).utc)
          }))
        end
        database.read do |db|
          project_id = project_id!(db, identity)
          row = db[:pr_merge_project_state].where(project_id: project_id).first
          row ? {
            "cursor" => row[:cursor],
            "backlog" => RuntimeControlPlane::Codec.load_json(row.fetch(:backlog_json))
          } : { "cursor" => nil, "backlog" => empty_backlog(Time.at(0).utc) }
        end
      end

      def write_project_state(identity, state, now:)
        if @dry_run
          @project_state[memory_key(identity)] = deep_copy(state)
          return state
        end
        database.transaction do |db|
          project_id = project_id!(db, identity)
          values = {
            cursor: state["cursor"],
            backlog_json: bounded_json(state.fetch("backlog"), "PR merge backlog"),
            updated_at: now.utc.iso8601(6)
          }
          db[:pr_merge_project_state].insert_conflict(
            target: :project_id, update: values
          ).insert(values.merge(project_id: project_id))
        end
        state
      end

      def row_for(db, project, identity, candidate, revision:)
        remote = candidate.fetch("remote")
        archive = candidate.fetch("archive")
        retry_state = candidate.fetch("retry")
        remote_state = remote.fetch("state")
        {
          reconciliation_id: candidate.fetch("key"), project_id: project.fetch(:project_id),
          task_id: task_id_for(db, project, candidate),
          task_generation: candidate.dig("observation", "task_generation"),
          repository_identity: identity.fetch("repository"),
          registration_id: identity.fetch("registration"),
          project_path: identity.fetch("project_path"),
          state_root_path: identity.fetch("hive_state_path"), host: identity.fetch("host"),
          default_branch: identity.fetch("default_branch"),
          pr_number: Integer(candidate.dig("pull_request", "number")),
          merge_sha: remote["merge_oid"], state: sql_state(remote_state, archive.fetch("status")),
          retry_failures: Integer(retry_state.fetch("failures")),
          retry_not_before: retry_state["not_before"], remote_state: remote_state,
          architecture_state: candidate.dig("architecture", "status"),
          archive_state: archive.fetch("status"),
          held: candidate.dig("observation", "held") == true ? 1 : 0,
          hold_reason: candidate.dig("observation", "hold_reason"), revision: revision,
          observation_json: bounded_json(candidate_evidence(candidate), "PR merge candidate"),
          observed_at: candidate.dig("observation", "state_file_mtime") || candidate.fetch("updated_at"),
          updated_at: candidate.fetch("updated_at"),
          completed_at: terminal?(candidate) ? candidate.fetch("updated_at") : nil
        }
      end

      def decode_candidate(row)
        candidate = RuntimeControlPlane::Codec.load_json(row.fetch(:observation_json))
        candidate["observation"].merge!(
          "task_generation" => row.fetch(:task_generation),
          "held" => row.fetch(:held) == 1, "hold_reason" => row[:hold_reason]
        )
        candidate["remote"].merge!(
          "state" => row.fetch(:remote_state), "merge_oid" => row[:merge_sha]
        )
        candidate["architecture"]["status"] = row.fetch(:architecture_state)
        candidate["archive"]["status"] = row.fetch(:archive_state)
        candidate["retry"] = {
          "failures" => row.fetch(:retry_failures), "not_before" => row[:retry_not_before]
        }
        candidate["updated_at"] = row.fetch(:updated_at)
        candidate["_revision"] = row.fetch(:revision)
        candidate
      end

      def validate_candidate!(candidate)
        key = candidate.fetch("key")
        raise Invalid, "candidate key is invalid" unless key.match?(/\A[a-f0-9]{64}\z/)
        raise Invalid, "task generation is missing" if
          candidate.dig("observation", "task_generation").to_s.empty?
        bounded_json(candidate, "PR merge candidate")
        candidate
      rescue KeyError, TypeError => error
        raise Invalid, "candidate is invalid: #{error.message}"
      end

      def verify_generation!(candidate, expected)
        unless candidate && candidate.dig("observation", "task_generation") == expected
          raise Hive::ConcurrentRunError, "merge reconciliation candidate changed before checkpoint"
        end
      end

      def project!(db, identity)
        project = db[:projects].where(registration_id: identity.fetch("registration")).first ||
          db[:projects].where(state_root_path: identity.fetch("hive_state_path")).first
        raise Invalid, "registered project identity is unavailable" unless project
        project
      end

      def project_id!(db, identity) = project!(db, identity).fetch(:project_id)

      def task_id_for(db, project, candidate)
        db[:task_subjects].where(
          project_id: project.fetch(:project_id),
          workflow_id: candidate.dig("task", "workflow"),
          task_slug: candidate.dig("task", "slug")
        ).get(:task_id)
      end

      def eligible_candidates(db, project_id, now)
        timestamp = now.utc.iso8601(6)
        pollable_hold = Sequel.&(
          { hold_reason: REMOTE_POLL_HOLD_REASONS },
          Sequel.~({ remote_state: TERMINAL_REMOTE_STATES, archive_state: "blocked" })
        )
        db[:pr_merge_reconciliations]
          .where(project_id: project_id)
          .exclude(archive_state: %w[archived superseded])
          .where(Sequel.|({ retry_not_before: nil }, Sequel.lit("retry_not_before <= ?", timestamp)))
          .where(Sequel.|({ held: 0 }, pollable_hold))
          .order(:reconciliation_id)
      end

      def candidate_evidence(candidate)
        evidence = deep_copy(candidate)
        evidence.delete("_revision")
        evidence.delete("updated_at")
        evidence.fetch("observation").delete_if do |key, _value|
          %w[task_generation held hold_reason].include?(key)
        end
        evidence.fetch("remote").delete_if { |key, _value| %w[state merge_oid].include?(key) }
        evidence.fetch("architecture").delete("status")
        evidence.fetch("archive").delete("status")
        evidence.delete("retry")
        evidence
      end

      def sql_state(remote_state, archive_state)
        return "failed" if archive_state == "failed"
        return "merged" if remote_state == "merged"
        return "closed" if remote_state == "closed_unmerged"
        "pending"
      end

      def terminal?(candidate)
        %w[archived superseded].include?(candidate.dig("archive", "status"))
      end

      def held_without_poll?(candidate)
        return false unless candidate.dig("observation", "held") == true
        reason = candidate.dig("observation", "hold_reason")
        return true unless remote_poll_hold_reason?(reason)
        TERMINAL_REMOTE_STATES.include?(candidate.dig("remote", "state")) &&
          candidate.dig("archive", "status") == "blocked"
      end

      def future_retry?(candidate, now)
        value = candidate.dig("retry", "not_before")
        value && Time.iso8601(value) > now
      rescue ArgumentError
        raise Invalid, "candidate retry timestamp is invalid"
      end

      def empty_backlog(time)
        { "watermark" => time.iso8601(6), "scanned_at" => nil,
          "complete" => false, "outcomes" => {} }
      end

      def bounded_json(value, label)
        json = RuntimeControlPlane::Codec.dump_json(value)
        raise Invalid, "#{label} exceeds #{MAX_EVIDENCE_BYTES} bytes" if
          json.bytesize > MAX_EVIDENCE_BYTES
        json
      end

      def memory_key(identity)
        [ identity.fetch("registration"), identity.fetch("repository") ].join("\0")
      end

      def deep_copy(value) = Marshal.load(Marshal.dump(value))

      def positive_number(value, label)
        number = Float(value)
        raise ArgumentError unless number.finite? && number.positive?
        number
      rescue ArgumentError, TypeError
        raise ArgumentError, "PR merge #{label} must be positive"
      end
    end
  end
end
