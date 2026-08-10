require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"

module Hive
  module Daemon
    # Project-local durable ledger for task-bound pull-request reconciliation.
    #
    # Architecture patrol keeps its own repository-wide catch-up cursor. This
    # store is deliberately task-specific: each candidate is fenced to the
    # exact task and marker generation observed before remote merge evidence,
    # architecture intake, and archive are attempted.
    class PrMergeReconciliationStore
      SCHEMA = "hive-pr-merge-reconciliation".freeze
      SCHEMA_VERSION = Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA)
      BASENAME = "pr-merge-reconciliation.json".freeze
      STATE_KEYS = %w[
        schema schema_version registration project_path hive_state_path host
        repository default_branch cursor backlog updated_at candidates
      ].freeze
      BACKLOG_KEYS = %w[watermark scanned_at complete outcomes].freeze
      OUTCOME_KEYS = %w[
        key project slug stage task_generation status reason candidate_key
        observed_at
      ].freeze
      CANDIDATE_KEYS = %w[
        key task observation pull_request remote architecture archive retry
        updated_at
      ].freeze
      TASK_KEYS = %w[project slug id workflow folder].freeze
      OBSERVATION_KEYS = %w[
        stage marker marker_generation task_generation state_file_mtime held
        hold_reason
      ].freeze
      PULL_REQUEST_KEYS = %w[url host repository number observed_head].freeze
      REMOTE_KEYS = %w[state merge_oid merged_at observed_at].freeze
      ARCHITECTURE_KEYS = %w[status request_id receipt last_error].freeze
      ARCHIVE_KEYS = %w[status receipt_digest archived_at last_error].freeze
      RETRY_KEYS = %w[failures not_before].freeze
      REMOTE_STATES = %w[
        unknown open merged closed_unmerged delivered_elsewhere ambiguous
      ].freeze
      ARCHITECTURE_STATES = %w[pending accepted deferred failed not_required].freeze
      ARCHIVE_STATES = %w[pending blocked archived failed superseded].freeze
      OUTCOME_STATES = %w[candidate rejected].freeze
      MAX_DIAGNOSTIC_BYTES = 500
      DEFAULT_BACKOFF_BASE_SEC = 60
      DEFAULT_BACKOFF_MAX_SEC = 3600
      TERMINAL_RETENTION_SEC = 7 * 24 * 60 * 60

      class Invalid < Hive::Error; end

      def initialize(dry_run: false, backoff_base_sec: DEFAULT_BACKOFF_BASE_SEC,
                     backoff_max_sec: DEFAULT_BACKOFF_MAX_SEC)
        @dry_run = dry_run
        @memory = {}
        @backoff_base_sec = positive_number(backoff_base_sec, "backoff base")
        @backoff_max_sec = positive_number(backoff_max_sec, "backoff maximum")
        if @backoff_max_sec < @backoff_base_sec
          raise ArgumentError, "PR merge backoff maximum cannot be below its base"
        end
      end

      def path(hive_state_path)
        File.join(hive_state_path, "daemon", BASENAME)
      end

      def transaction(identity, now: Time.now.utc)
        with_lock(identity.fetch("hive_state_path")) do
          state = load(identity) || build(identity, now: now)
          yield(state)
          compact_terminal_candidates!(state, now: now)
          state["updated_at"] = now.utc.iso8601(6)
          validate!(state)
          persist(identity.fetch("hive_state_path"), state)
          state
        end
      end

      def load(identity)
        raw = authoritative_bytes(identity.fetch("hive_state_path"))
        return nil unless raw

        state = JSON.parse(raw)
        validate!(state)
        assert_identity!(state, identity)
        state
      rescue JSON::ParserError, Invalid, KeyError, TypeError, ArgumentError => e
        quarantine(identity.fetch("hive_state_path"), raw.to_s, reason: e.message, observed: identity)
        raise Invalid, "cannot continue PR merge reconciliation: #{e.message}"
      rescue SystemCallError, IOError => e
        raise Invalid, "cannot read PR merge reconciliation: #{e.class}: #{e.message}"
      end

      def build(identity, now:)
        timestamp = now.utc.iso8601(6)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "registration" => identity.fetch("registration"),
          "project_path" => identity.fetch("project_path"),
          "hive_state_path" => identity.fetch("hive_state_path"),
          "host" => identity.fetch("host"),
          "repository" => identity.fetch("repository"),
          "default_branch" => identity.fetch("default_branch"),
          "cursor" => nil,
          "backlog" => {
            "watermark" => timestamp,
            "scanned_at" => nil,
            "complete" => false,
            "outcomes" => {}
          },
          "updated_at" => timestamp,
          "candidates" => {}
        }
      end

      def candidate_key(project:, slug:, task_generation:, pull_request:)
        Digest::SHA256.hexdigest(
          JSON.generate(
            [
              project.to_s,
              slug.to_s,
              task_generation.to_s,
              *%w[url host repository number observed_head].map {
                |field| pull_request[field]
              }
            ]
          )
        )
      end

      def outcome_key(project:, slug:, task_generation:)
        Digest::SHA256.hexdigest(
          JSON.generate([ project.to_s, slug.to_s, task_generation.to_s ])
        )
      end

      def next_candidate(state, now:)
        keys = state.fetch("candidates").keys.sort
        return nil if keys.empty?

        cursor = state["cursor"]
        start = cursor && keys.include?(cursor) ? keys.index(cursor) + 1 : 0
        keys.rotate(start).each do |key|
          candidate = state.fetch("candidates").fetch(key)
          next if %w[archived superseded].include?(candidate.dig("archive", "status"))
          next if candidate.dig("observation", "held") == true
          not_before = candidate.dig("retry", "not_before")
          next if not_before && Time.iso8601(not_before) > now

          return candidate
        end
        nil
      end

      def advance_cursor!(state, key)
        state["cursor"] = key
      end

      def clear_retry!(candidate)
        candidate["retry"] = { "failures" => 0, "not_before" => nil }
      end

      def record_failure!(candidate, error, now:)
        failures = candidate.dig("retry", "failures").to_i + 1
        exponent = [ failures - 1, 20 ].min
        delay = [ @backoff_base_sec * (2**exponent), @backoff_max_sec ].min
        candidate["retry"] = {
          "failures" => failures,
          "not_before" => (now + delay).utc.iso8601(6)
        }
        candidate["updated_at"] = now.utc.iso8601(6)
        bounded = "#{error.class}: #{error.message}"[0, MAX_DIAGNOSTIC_BYTES]
        candidate["archive"]["last_error"] = bounded
        bounded
      end

      def compact_terminal_candidates!(state, now:)
        cutoff = now - TERMINAL_RETENTION_SEC
        removed = state.fetch("candidates").delete_if do |_key, candidate|
          next false unless
            %w[archived superseded].include?(candidate.dig("archive", "status"))

          Time.iso8601(candidate.fetch("updated_at")) < cutoff
        rescue ArgumentError
          false
        end
        state["cursor"] = nil if state["cursor"] && !state.fetch("candidates").key?(state["cursor"])
        removed
      end

      def validate!(state)
        invalid!("state must be an object") unless state.is_a?(Hash)
        invalid!("state fields do not match v1") unless state.keys.sort == STATE_KEYS.sort
        invalid!("unexpected reconciliation schema") unless state["schema"] == SCHEMA
        invalid!("unsupported reconciliation schema version") unless
          state["schema_version"] == SCHEMA_VERSION
        %w[registration project_path hive_state_path host repository default_branch].each do |key|
          invalid!("#{key} is missing") unless nonempty_string?(state[key])
        end
        timestamp!(state["updated_at"], "updated_at")
        invalid!("cursor is invalid") unless state["cursor"].nil? ||
          state["cursor"].to_s.match?(/\A[a-f0-9]{64}\z/)
        validate_backlog!(state.fetch("backlog"))
        candidates = state["candidates"]
        invalid!("candidates must be an object") unless candidates.is_a?(Hash)
        candidates.each do |key, candidate|
          invalid!("candidate key is invalid") unless key.match?(/\A[a-f0-9]{64}\z/)
          validate_candidate!(candidate, key)
        end
        invalid!("cursor does not name a candidate") if state["cursor"] &&
          !candidates.key?(state["cursor"])
        state
      end

      def assert_identity!(state, identity)
        checks = {
          "registration" => "registration",
          "project_path" => "project path",
          "hive_state_path" => "state path",
          "host" => "repository host",
          "repository" => "repository identity",
          "default_branch" => "default branch"
        }
        checks.each do |key, label|
          next if state.fetch(key) == identity.fetch(key)

          raise Invalid, "#{label} changed from #{state.fetch(key).inspect} " \
                         "to #{identity.fetch(key).inspect}"
        end
        true
      end

      private

      def validate_backlog!(backlog)
        invalid!("backlog fields do not match v1") unless
          backlog.is_a?(Hash) && backlog.keys.sort == BACKLOG_KEYS.sort
        timestamp!(backlog["watermark"], "backlog watermark")
        timestamp!(backlog["scanned_at"], "backlog scanned_at", nullable: true)
        invalid!("backlog complete must be boolean") unless
          [ true, false ].include?(backlog["complete"])
        outcomes = backlog["outcomes"]
        invalid!("backlog outcomes must be an object") unless outcomes.is_a?(Hash)
        outcomes.each do |key, outcome|
          invalid!("backlog outcome key is invalid") unless
            key.match?(/\A[a-f0-9]{64}\z/)
          validate_exact_object!(outcome, OUTCOME_KEYS, "backlog outcome")
          invalid!("backlog outcome key mismatch") unless outcome["key"] == key
          %w[project slug stage].each do |field|
            invalid!("backlog outcome #{field} is invalid") unless
              nonempty_string?(outcome[field])
          end
          invalid!("backlog outcome task generation is invalid") unless
            outcome["task_generation"].to_s.match?(/\A[a-f0-9]{64}\z/)
          invalid!("backlog outcome status is invalid") unless
            OUTCOME_STATES.include?(outcome["status"])
          invalid!("backlog outcome reason is invalid") unless
            outcome["reason"].nil? || nonempty_string?(outcome["reason"])
          invalid!("backlog outcome candidate key is invalid") unless
            outcome["candidate_key"].nil? ||
            outcome["candidate_key"].to_s.match?(/\A[a-f0-9]{64}\z/)
          timestamp!(outcome["observed_at"], "backlog outcome observed_at")
        end
      end

      def validate_candidate!(candidate, key)
        invalid!("candidate must be an object") unless candidate.is_a?(Hash)
        invalid!("candidate fields do not match v1") unless
          candidate.keys.sort == CANDIDATE_KEYS.sort
        invalid!("candidate key mismatch") unless candidate["key"] == key
        validate_exact_object!(candidate["task"], TASK_KEYS, "candidate task")
        task = candidate.fetch("task")
        %w[project slug workflow folder].each do |field|
          invalid!("candidate task #{field} is invalid") unless nonempty_string?(task[field])
        end
        invalid!("candidate task id is invalid") unless task["id"].nil? || task["id"].is_a?(Integer)
        validate_observation!(candidate.fetch("observation"))
        validate_pull_request!(candidate.fetch("pull_request"))
        validate_remote!(candidate.fetch("remote"))
        validate_phase!(
          candidate.fetch("architecture"), ARCHITECTURE_KEYS,
          ARCHITECTURE_STATES, "architecture"
        )
        validate_phase!(
          candidate.fetch("archive"), ARCHIVE_KEYS,
          ARCHIVE_STATES, "archive"
        )
        retry_state = candidate.fetch("retry")
        validate_exact_object!(retry_state, RETRY_KEYS, "candidate retry")
        invalid!("retry failures is invalid") unless
          retry_state["failures"].is_a?(Integer) && retry_state["failures"] >= 0
        timestamp!(retry_state["not_before"], "retry not_before", nullable: true)
        timestamp!(candidate["updated_at"], "candidate updated_at")
      end

      def validate_observation!(observation)
        validate_exact_object!(observation, OBSERVATION_KEYS, "candidate observation")
        invalid!("candidate stage is invalid") unless
          observation["stage"].to_s.match?(/\A[0-9]+-[a-z0-9][a-z0-9-]*\z/)
        invalid!("candidate marker is invalid") unless nonempty_string?(observation["marker"])
        %w[marker_generation task_generation].each do |field|
          invalid!("candidate #{field} is invalid") unless
            observation[field].to_s.match?(/\A[a-f0-9]{64}\z/)
        end
        timestamp!(observation["state_file_mtime"], "candidate state_file_mtime", nullable: true)
        invalid!("candidate held flag is invalid") unless
          [ true, false ].include?(observation["held"])
        invalid!("candidate hold reason is invalid") unless
          observation["hold_reason"].nil? || nonempty_string?(observation["hold_reason"])
      end

      def validate_pull_request!(pull_request)
        validate_exact_object!(pull_request, PULL_REQUEST_KEYS, "candidate pull request")
        %w[url host repository].each do |field|
          invalid!("candidate pull request #{field} is invalid") unless
            nonempty_string?(pull_request[field])
        end
        invalid!("candidate pull request number is invalid") unless
          pull_request["number"].is_a?(Integer) && pull_request["number"].positive?
        invalid!("candidate observed head is invalid") unless
          pull_request["observed_head"].nil? ||
          pull_request["observed_head"].to_s.match?(/\A[a-f0-9]{40,64}\z/)
      end

      def validate_remote!(remote)
        validate_exact_object!(remote, REMOTE_KEYS, "candidate remote")
        invalid!("candidate remote state is invalid") unless
          REMOTE_STATES.include?(remote["state"])
        invalid!("candidate merge oid is invalid") unless remote["merge_oid"].nil? ||
          remote["merge_oid"].to_s.match?(/\A[a-f0-9]{40,64}\z/)
        timestamp!(remote["merged_at"], "candidate merged_at", nullable: true)
        timestamp!(remote["observed_at"], "candidate observed_at", nullable: true)
      end

      def validate_phase!(phase, keys, states, label)
        validate_exact_object!(phase, keys, "candidate #{label}")
        invalid!("candidate #{label} status is invalid") unless states.include?(phase["status"])
        phase.each do |key, value|
          next if key == "status" || value.nil?

          invalid!("candidate #{label} #{key} is invalid") unless value.is_a?(String)
        end
        timestamp!(phase["archived_at"], "candidate archived_at", nullable: true) if
          phase.key?("archived_at")
      end

      def validate_exact_object!(value, keys, label)
        invalid!("#{label} fields do not match v1") unless
          value.is_a?(Hash) && value.keys.sort == keys.sort
      end

      def timestamp!(value, label, nullable: false)
        return if nullable && value.nil?

        invalid!("#{label} is invalid") unless value.is_a?(String)
        Time.iso8601(value)
      rescue ArgumentError
        invalid!("#{label} is invalid")
      end

      def nonempty_string?(value)
        value.is_a?(String) && !value.empty? && !value.include?("\0")
      end

      def invalid!(message)
        raise Invalid, message
      end

      def with_lock(hive_state_path)
        return yield if @dry_run

        lock_path = "#{path(hive_state_path)}.lock"
        FileUtils.mkdir_p(File.dirname(lock_path), mode: 0o700)
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      end

      def authoritative_bytes(hive_state_path)
        return @memory[path(hive_state_path)] if @dry_run
        return nil unless File.file?(path(hive_state_path))

        File.binread(path(hive_state_path))
      end

      def persist(hive_state_path, state)
        bytes = "#{JSON.generate(state)}\n"
        if @dry_run
          @memory[path(hive_state_path)] = bytes
          return
        end
        target = path(hive_state_path)
        Hive::AtomicFile.write(target, bytes, mode: 0o600)
        File.chmod(0o600, target)
        Hive::AtomicFile.fsync_directory(File.dirname(target))
      end

      def quarantine(hive_state_path, bytes, reason:, observed:)
        return if @dry_run || bytes.empty?

        root = File.join(hive_state_path, "daemon", "quarantine", "pr-merge-reconciliation")
        FileUtils.mkdir_p(root, mode: 0o700)
        digest = Digest::SHA256.hexdigest(bytes)
        payload_path = File.join(root, "#{digest}.payload")
        metadata_path = File.join(root, "#{digest}.json")
        Hive::AtomicFile.write(payload_path, bytes, mode: 0o600) unless
          File.file?(payload_path)
        return if File.file?(metadata_path)

        evidence = {
          "schema" => "hive-pr-merge-reconciliation-conflict",
          "schema_version" => 1,
          "reason" => reason.to_s[0, MAX_DIAGNOSTIC_BYTES],
          "observed" => observed,
          "authoritative_sha256" => digest,
          "payload_path" => payload_path,
          "quarantined_at" => Time.now.utc.iso8601(6)
        }
        Hive::AtomicFile.write(
          metadata_path,
          "#{JSON.generate(evidence)}\n",
          mode: 0o600
        )
      rescue SystemCallError, IOError
        nil
      end

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
