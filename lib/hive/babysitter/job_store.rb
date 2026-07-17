require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/paths"
require "hive/task_projection"
require "hive/babysitter/job"

module Hive
  module Babysitter
    class JobStore
      CURRENT_SCHEMA = "hive-babysitter-current-job".freeze
      CURRENT_VERSION = 1
      REPLACEMENT_TERMINAL_STATES = %w[CLOSED INVALID].freeze

      class Error < Hive::Error; end
      class CorruptRecord < Error; end
      class UnsupportedVersion < Error; end
      class InconsistentRecord < Error; end
      class RecordNotFound < Error; end
      class StaleClaim < Error; end
      class ReplacementBlocked < Error; end

      attr_reader :project_root, :root

      def initialize(project_root:, clock: -> { Time.now.utc })
        @project_root = File.expand_path(project_root)
        @root = Hive::Paths.babysitter_jobs_root(@project_root)
        @clock = clock
      end

      def reserve!(project:, task_id:, task_slug:, task_generation:, repository:, pr_number:,
                   pr_url:, branch:, head_sha:, head_generation:, finalize_attempt_id:,
                   task_folder:, now: @clock.call)
        identity = Hive::Babysitter::Job.identity(
          project: project, task_id: task_id, task_slug: task_slug,
          task_generation: task_generation, repository: repository, pr_number: pr_number
        )
        with_current_lock(identity) do
          current = read_current_index(identity, rebuild: true)
          if current && current.fetch("job_id") != Hive::Babysitter::Job.job_id(identity)
            raise ReplacementBlocked, "a different babysitter job is current for this task generation"
          end
          record = reserve_under_lock(
            identity: identity, pr_url: pr_url, branch: branch, task_folder: task_folder,
            head_sha: head_sha, head_generation: head_generation,
            finalize_attempt_id: finalize_attempt_id, now: now
          )
          write_current_index(identity, record.fetch("job_id"), now: now)
          record
        end
      end

      def reserve_replacement!(old_job_id:, remote_state:, remote_observed_at:, **attributes)
        state = remote_state.to_s.upcase
        unless REPLACEMENT_TERMINAL_STATES.include?(state)
          raise ReplacementBlocked, "old PR replacement requires exact CLOSED or INVALID evidence"
        end
        old = read(old_job_id)
        identity = Hive::Babysitter::Job.identity(
          project: attributes.fetch(:project), task_id: attributes.fetch(:task_id),
          task_slug: attributes.fetch(:task_slug), task_generation: attributes.fetch(:task_generation),
          repository: attributes.fetch(:repository), pr_number: attributes.fetch(:pr_number)
        )
        unless same_task_generation?(old.fetch("identity"), identity)
          raise ReplacementBlocked, "replacement must keep the same canonical task generation"
        end
        now = attributes.fetch(:now, @clock.call)
        with_current_lock(identity) do
          current = read_current_index(identity, rebuild: true)
          unless current&.fetch("job_id") == old_job_id
            raise ReplacementBlocked, "old babysitter job is no longer current"
          end
          proof = {
            "state" => state,
            "observed_at" => Time.iso8601(remote_observed_at.to_s).utc.iso8601,
            "old_job_id" => old_job_id,
            "old_pr_number" => old.dig("identity", "pr_number")
          }
          replacement = reserve_under_lock(
            identity: identity,
            pr_url: attributes.fetch(:pr_url), branch: attributes.fetch(:branch),
            task_folder: attributes.fetch(:task_folder), head_sha: attributes.fetch(:head_sha),
            head_generation: attributes.fetch(:head_generation),
            finalize_attempt_id: attributes.fetch(:finalize_attempt_id), now: now,
            supersedes_job_id: old_job_id, replacement_proof: proof
          )
          mutate(old_job_id) do |candidate|
            candidate["state"] = "superseded"
            candidate["superseded_by_job_id"] = replacement.fetch("job_id")
            candidate["updated_at"] = now.utc.iso8601(6)
            candidate
          end
          write_current_index(identity, replacement.fetch("job_id"), now: now)
          replacement
        end
      rescue ArgumentError => e
        raise ReplacementBlocked, "replacement evidence timestamp is invalid: #{e.message}"
      end

      def activate!(job_id, handoff_event_id:, finalize_attempt_id:, now: @clock.call)
        mutate(job_id) do |record|
          if record.fetch("state") == "active"
            unless record["journal_handoff_event_id"] == handoff_event_id &&
                   record["finalize_attempt_id"] == finalize_attempt_id
              raise InconsistentRecord, "active babysitter job does not match handoff"
            end
            next record
          end
          unless record.fetch("state") == "inactive"
            raise InconsistentRecord, "only an inactive babysitter job can activate"
          end
          verify_handoff!(record, handoff_event_id, finalize_attempt_id)
          record["state"] = "active"
          record["journal_handoff_event_id"] = handoff_event_id
          record["finalize_attempt_id"] = finalize_attempt_id
          record["updated_at"] = now.utc.iso8601(6)
          record
        end
      end

      def repair_activations!(now: @clock.call)
        jobs.filter_map do |record|
          next unless record.fetch("state") == "inactive"

          records = Hive::TaskProjection.read_journal(
            File.join(record.fetch("task_folder"), Hive::TaskJournal::JOURNAL_BASENAME)
          )
          handoff = records.reverse_each.find do |event|
            %w[finalized finalize_attempt_adopted].include?(event["event_type"]) &&
              event.dig("payload", "job_id") == record.fetch("job_id") &&
              event["task_generation"] == record.dig("identity", "task_generation")
          end
          next unless handoff

          activate!(
            record.fetch("job_id"), handoff_event_id: handoff.fetch("event_id"),
            finalize_attempt_id: handoff.dig("payload", "finalize_attempt_id"), now: now
          )
        end
      end

      def claim!(job_id, owner:, now: @clock.call, lease_sec: 300, claim_resolver: nil,
                 owner_pid: nil, owner_process_start_time: nil)
        validate_lease!(lease_sec)
        token = nil
        mutate(job_id) do |record|
          next record unless record.fetch("state") == "active"
          ensure_current!(record)
          active = active_claim(record)
          if active && Time.iso8601(active.fetch("expires_at")) > now
            next record
          end
          if active
            resolved = begin
              claim_resolver&.call(json_copy(active))
            rescue StandardError
              :unresolved
            end
            next record unless resolved == :resolved

            active["state"] = "superseded"
            active["finished_at"] = now.utc.iso8601(6)
            active["outcome"] = "expired_owner_resolved"
          end
          fence = record.fetch("claims").filter_map { |claim| claim["claim_fence"] }.max.to_i + 1
          claim = {
            "owner" => owner.to_s,
            "owner_pid" => owner_pid,
            "owner_process_start_time" => owner_process_start_time,
            "claim_fence" => fence,
            "state" => "active",
            "claimed_at" => now.utc.iso8601(6),
            "heartbeat_at" => now.utc.iso8601(6),
            "expires_at" => (now + lease_sec).utc.iso8601(6),
            "finished_at" => nil,
            "outcome" => nil
          }
          record.fetch("claims") << claim
          record["updated_at"] = now.utc.iso8601(6)
          token = token_for(record, claim)
          record
        end
        token
      end

      def renew!(token, now: @clock.call, lease_sec: 300)
        validate_lease!(lease_sec)
        mutate(token.fetch("job_id")) do |record|
          claim = validate_token!(record, token, now: now)
          claim["heartbeat_at"] = now.utc.iso8601(6)
          claim["expires_at"] = (now + lease_sec).utc.iso8601(6)
          record["updated_at"] = now.utc.iso8601(6)
          record
        end
      end

      def release!(token, outcome:, now: @clock.call)
        mutate(token.fetch("job_id")) do |record|
          claim = validate_token!(record, token, now: now, allow_expired: true)
          claim["state"] = "released"
          claim["finished_at"] = now.utc.iso8601(6)
          claim["outcome"] = outcome.to_s
          record["updated_at"] = now.utc.iso8601(6)
          record
        end
      end

      def authorize!(token, expected_sha:, head_generation:, finalize_attempt_id: nil, now: @clock.call)
        with_job_lock(token.fetch("job_id")) do
          record = read(token.fetch("job_id"))
          validate_token!(record, token, now: now)
          ensure_current!(record)
          raise StaleClaim, "babysitter expected SHA is stale" unless record["head_sha"] == expected_sha
          unless record["head_generation"] == head_generation
            raise StaleClaim, "babysitter head generation is stale"
          end
          if finalize_attempt_id && record["finalize_attempt_id"] != finalize_attempt_id
            raise StaleClaim, "babysitter finalize attempt is stale"
          end
          true
        end
      end

      def validate_event_authority!(record, now: @clock.call)
        producer = record.fetch("producer")
        payload = record.fetch("payload")
        token = {
          "job_id" => producer.fetch("job_id"),
          "claim_fence" => producer.fetch("claim_fence"),
          "owner" => producer.fetch("owner", nil)
        }
        with_job_lock(token.fetch("job_id")) do
          job = read(token.fetch("job_id"))
          validate_token!(job, token, now: now, owner_optional: true)
          ensure_current!(job)
          identity = job.fetch("identity")
          mismatches = []
          mismatches << "task_generation" unless record["task_generation"] == identity["task_generation"]
          mismatches << "job_id" unless payload["job_id"] == job["job_id"]
          mismatches << "repository" unless payload["repository"] == identity["repository"]
          mismatches << "pr_number" unless payload["pr_number"] == identity["pr_number"]
          if record["event_type"] == "head_superseded"
            mismatches << "head_sha" unless payload["head_sha"] != job["head_sha"]
            mismatches << "head_generation" unless payload["head_generation"] == job["head_generation"] + 1
          else
            mismatches << "head_sha" unless payload["head_sha"] == job["head_sha"]
            mismatches << "head_generation" unless payload["head_generation"] == job["head_generation"]
          end
          mismatches << "finalize_attempt_id" unless payload["finalize_attempt_id"] == job["finalize_attempt_id"]
          raise StaleClaim, "babysitter event authority mismatch: #{mismatches.join(', ')}" unless mismatches.empty?
          true
        end
      rescue KeyError => e
        raise StaleClaim, "babysitter event authority missing #{e.key}"
      end

      def adopt_attempt!(job_id, handoff_event_id:, finalize_attempt_id:, now: @clock.call)
        mutate(job_id) do |record|
          verify_handoff!(record, handoff_event_id, finalize_attempt_id)
          record["journal_handoff_event_id"] = handoff_event_id
          record["finalize_attempt_id"] = finalize_attempt_id
          record["updated_at"] = now.utc.iso8601(6)
          record
        end
      end

      def advance_head!(token, previous_sha:, head_sha:, head_generation:, now: @clock.call)
        mutate(token.fetch("job_id")) do |record|
          validate_token!(record, token, now: now)
          unless record["head_sha"] == previous_sha && head_generation == record["head_generation"] + 1
            raise StaleClaim, "babysitter head advancement is stale"
          end
          Hive::Babysitter::Job.validate_sha!(head_sha)
          record["head_sha"] = head_sha
          record["head_generation"] = head_generation
          record["updated_at"] = now.utc.iso8601(6)
          record
        end
      end

      def mark_terminal!(token, now: @clock.call)
        mutate(token.fetch("job_id")) do |record|
          validate_token!(record, token, now: now)
          ensure_current!(record)
          record["state"] = "terminal"
          record["updated_at"] = now.utc.iso8601(6)
          record
        end
      end

      # Retire an operational job after an operator-authored no-PR approval.
      # The journal event is authoritative; this method only prevents a future
      # daemon tick from claiming a branch whose task is now archive-eligible.
      # It is repair-safe when the approval append succeeded before this write.
      def retire_after_no_pr_approval!(job_id, approval_event_id:, now: @clock.call)
        mutate(job_id) do |record|
          ensure_current!(record)
          verify_operator_event!(record, approval_event_id, "no_pr_approved")
          if (claim = active_claim(record))
            if Time.iso8601(claim.fetch("expires_at")) > now
              raise StaleClaim, "live babysitter claim prevents no-PR retirement"
            end
            claim["state"] = "superseded"
            claim["finished_at"] = now.utc.iso8601(6)
            claim["outcome"] = "operator_terminal_approval"
          end
          record["state"] = "terminal"
          record["updated_at"] = now.utc.iso8601(6)
          record
        end
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "no-PR retirement evidence is invalid: #{e.message}"
      end

      # Re-enable a retired job only after the append-only re-arm event exists.
      # A retry after journal-then-registry process death safely repairs the
      # operational state without creating a new job or claim owner.
      def rearm_after_approval!(job_id, rearm_event_id:, now: @clock.call)
        mutate(job_id) do |record|
          ensure_current!(record)
          verify_operator_event!(record, rearm_event_id, "finalization_rearmed")
          unless %w[terminal active].include?(record.fetch("state"))
            raise InconsistentRecord, "only a retired babysitter job can be re-armed"
          end
          if (claim = active_claim(record))
            raise StaleClaim, "active babysitter claim prevents operator re-arm" if
              Time.iso8601(claim.fetch("expires_at")) > now

            claim["state"] = "superseded"
            claim["finished_at"] = now.utc.iso8601(6)
            claim["outcome"] = "operator_rearm_repair"
          end
          record["state"] = "active"
          record["updated_at"] = now.utc.iso8601(6)
          record
        end
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "operator re-arm evidence is invalid: #{e.message}"
      end

      def current_job(task_slug:, task_generation:)
        identity = jobs.map { |record| record.fetch("identity") }.find do |candidate|
          candidate["task_slug"] == task_slug.to_s && candidate["task_generation"] == task_generation
        end
        return nil unless identity

        index = read_current_index(identity, rebuild: true)
        index && read(index.fetch("job_id"))
      end

      def jobs
        return [] unless Dir.exist?(root)

        Dir.glob(File.join(root, "*.json")).sort.map do |path|
          read(File.basename(path, ".json"))
        end
      end

      def read(job_id)
        path = job_path(job_id)
        data = JSON.parse(File.binread(path))
        unless data["schema_version"] == Hive::Babysitter::Job::SCHEMA_VERSION
          raise UnsupportedVersion, "unsupported babysitter job version at #{path}"
        end
        Hive::Babysitter::Job.validate!(data)
        raise InconsistentRecord, "babysitter job filename does not match identity" unless data["job_id"] == job_id

        data
      rescue Errno::ENOENT
        raise RecordNotFound, "babysitter job not found: #{job_id}"
      rescue JSON::ParserError, Hive::Babysitter::Job::Invalid => e
        raise CorruptRecord, "invalid babysitter job #{job_id}: #{e.message}"
      end

      def job_path(job_id)
        unless job_id.to_s.match?(/\Absj-v1-[0-9a-f]{32}\z/)
          raise RecordNotFound, "invalid babysitter job id"
        end
        File.join(root, "#{job_id}.json")
      end

      private

      def reserve_under_lock(identity:, pr_url:, branch:, task_folder:, head_sha:, head_generation:,
                             finalize_attempt_id:, now:, supersedes_job_id: nil, replacement_proof: nil)
        ensure_task_folder!(task_folder)
        candidate = Hive::Babysitter::Job.build(
          identity: identity, pr_url: pr_url, branch: branch, task_folder: task_folder,
          head_sha: head_sha, head_generation: head_generation,
          finalize_attempt_id: finalize_attempt_id, now: now,
          supersedes_job_id: supersedes_job_id, replacement_proof: replacement_proof
        )
        path = job_path(candidate.fetch("job_id"))
        with_job_lock(candidate.fetch("job_id")) do
          return read(candidate.fetch("job_id")) if File.file?(path)

          write(path, candidate)
          candidate
        end
      end

      def mutate(job_id)
        with_job_lock(job_id) do
          record = read(job_id)
          result = yield(record)
          Hive::Babysitter::Job.validate!(result)
          write(job_path(job_id), result)
          result
        end
      end

      def verify_handoff!(record, event_id, finalize_attempt_id)
        records = Hive::TaskProjection.read_journal(
          File.join(record.fetch("task_folder"), Hive::TaskJournal::JOURNAL_BASENAME)
        )
        handoff = records.find { |event| event["event_id"] == event_id }
        unless handoff && %w[finalized finalize_attempt_adopted].include?(handoff["event_type"]) &&
               handoff.dig("payload", "job_id") == record.fetch("job_id") &&
               handoff.dig("payload", "finalize_attempt_id") == finalize_attempt_id &&
               handoff["task_generation"] == record.dig("identity", "task_generation")
          raise InconsistentRecord, "babysitter activation lacks matching authoritative handoff"
        end
      end

      def verify_operator_event!(record, event_id, event_type)
        records = Hive::TaskProjection.read_journal(
          File.join(record.fetch("task_folder"), Hive::TaskJournal::JOURNAL_BASENAME)
        )
        event = records.find { |candidate| candidate["event_id"] == event_id }
        unless event && event["event_type"] == event_type &&
               event.dig("producer", "kind") == "operator" &&
               event.dig("payload", "job_id") == record.fetch("job_id") &&
               event["task_generation"] == record.dig("identity", "task_generation")
          raise InconsistentRecord, "babysitter operational transition lacks matching operator event"
        end
      end

      def validate_token!(record, token, now:, allow_expired: false, owner_optional: false)
        claim = active_claim(record)
        unless claim && claim["claim_fence"] == token["claim_fence"] &&
               (owner_optional || claim["owner"] == token["owner"])
          raise StaleClaim, "babysitter claim fence is stale"
        end
        if !allow_expired && Time.iso8601(claim.fetch("expires_at")) <= now
          raise StaleClaim, "babysitter claim lease expired"
        end
        claim
      end

      def active_claim(record)
        record.fetch("claims").reverse_each.find { |claim| claim["state"] == "active" }
      end

      def token_for(record, claim)
        {
          "job_id" => record.fetch("job_id"),
          "claim_fence" => claim.fetch("claim_fence"),
          "owner" => claim.fetch("owner")
        }.freeze
      end

      def ensure_current!(record)
        index = read_current_index(record.fetch("identity"), rebuild: true)
        unless index&.fetch("job_id") == record.fetch("job_id")
          raise StaleClaim, "babysitter job is no longer current"
        end
      end

      def same_task_generation?(left, right)
        %w[project task_id task_slug task_generation repository].all? { |key| left[key] == right[key] }
      end

      def ensure_task_folder!(path)
        expanded = File.expand_path(path)
        stages = File.join(project_root, ".hive-state", "stages") + File::SEPARATOR
        unless expanded.start_with?(stages) && File.directory?(expanded)
          raise InconsistentRecord, "babysitter task folder must be an existing project stage path"
        end
      end

      def validate_lease!(lease_sec)
        return if lease_sec.is_a?(Numeric) && lease_sec.positive?

        raise ArgumentError, "babysitter lease must be positive"
      end

      def current_key(identity)
        fields = %w[project task_id task_slug task_generation].map { |key| "#{key}=#{identity.fetch(key)}" }
        ::Digest::SHA256.hexdigest(fields.join("\0"))
      end

      def current_path(identity)
        File.join(Hive::Paths.babysitter_current_root(project_root), "#{current_key(identity)}.json")
      end

      def read_current_index(identity, rebuild:)
        path = current_path(identity)
        data = JSON.parse(File.binread(path))
        unless data["schema"] == CURRENT_SCHEMA && data["schema_version"] == CURRENT_VERSION &&
               data["task_key"] == current_key(identity)
          raise CorruptRecord, "invalid babysitter current-job index"
        end
        data
      rescue Errno::ENOENT
        rebuild ? rebuild_current_index(identity) : nil
      rescue JSON::ParserError
        rebuild ? rebuild_current_index(identity) : raise(CorruptRecord, "invalid babysitter current-job index")
      end

      def rebuild_current_index(identity)
        candidates = jobs.select do |record|
          same_task_generation?(record.fetch("identity"), identity) &&
            record.fetch("state") != "superseded"
        end
        raise CorruptRecord, "multiple current babysitter jobs for task generation" if candidates.size > 1
        return nil if candidates.empty?

        write_current_index(identity, candidates.first.fetch("job_id"), now: @clock.call)
      end

      def write_current_index(identity, job_id, now:)
        body = {
          "schema" => CURRENT_SCHEMA,
          "schema_version" => CURRENT_VERSION,
          "task_key" => current_key(identity),
          "job_id" => job_id,
          "updated_at" => now.utc.iso8601(6)
        }
        write(current_path(identity), body)
        body
      end

      def with_current_lock(identity, &block)
        with_lock(File.join(Hive::Paths.babysitter_current_locks_root(project_root), "#{current_key(identity)}.lock"), &block)
      end

      def with_job_lock(job_id, &block)
        with_lock(File.join(Hive::Paths.babysitter_job_locks_root(project_root), "#{job_id}.lock"), &block)
      end

      def with_lock(path)
        ensure_private_directory(File.dirname(path))
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      end

      def write(path, data)
        ensure_private_directory(File.dirname(path))
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(data)}\n", mode: 0o600)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def ensure_private_directory(path)
        FileUtils.mkdir_p(path, mode: 0o700)
        File.chmod(0o700, path)
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
