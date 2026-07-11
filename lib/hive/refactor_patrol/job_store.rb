require "json"
require "fileutils"
require "digest"
require "time"
require "hive/atomic_file"
require "hive/refactor_patrol/pr_manifest"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    # Authoritative v2 lifecycle storage. A job aggregate owns discovery and
    # action receipts; the indexes below are disposable projections rebuilt by
    # scanning terminal aggregates.
    class JobStore
      SCHEMA = "hive-refactor-patrol-job".freeze
      SCHEMA_VERSION = 2
      ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/
      STATES = %w[queued analyzing classified acting blocked complete].freeze
      DISPOSITIONS = %w[accepted flagged suppressed].freeze
      ZERO_REASONS = %w[no_mapped_slice no_theses all_suppressed].freeze
      TOP_LEVEL_KEYS = %w[
        schema schema_version job_id source analysis_sha policy state complete
        dispositions feature_results review_errors zero_reason attempts actions
        created_at updated_at
      ].freeze
      SOURCE_KEYS = %w[
        url number repository registration base_branch base_sha merge_sha
        merged_at changed_paths manifest_checksum
      ].freeze
      POLICY_KEYS = %w[discovery auto_fix issue_filing action epoch captured_at].freeze
      POLICY_ACTION_KEYS = %w[
        default_branch auto_fix_agent min_confidence commands caps
        issue_min_leverage_score
      ].freeze
      POLICY_COMMAND_KEYS = %w[docs format lint typecheck test].freeze
      POLICY_CAP_KEYS = %w[
        single_feature_only allow_dependency_bumps allow_public_api_changes
        max_files max_diff_lines allow_cross_feature
      ].freeze
      DISPOSITION_KEYS = %w[id feature_id fingerprint score admissible reasons reference thesis family_id].freeze
      FEATURE_RESULT_KEYS = %w[feature_id complete thesis_ids errors].freeze
      ACTION_REQUIRED_KEYS = %w[
        canonical_action_id thesis_id thesis_fingerprint kind owner_job_id
        outcome terminal receipts
      ].freeze
      ACTION_KEYS = (ACTION_REQUIRED_KEYS + %w[
        family_id claims created_at updated_at
      ]).freeze
      ACTION_KINDS = %w[fix issue].freeze
      ACTION_CLAIM_KEYS = %w[
        owner owner_pid owner_process_start_time generation state authority
        claimed_at heartbeat_at expires_at pid process_start_time pgid
        finished_at outcome next_eligible_at
      ].freeze
      ACTIVE_ACTION_CLAIM_STATES = %w[claimed running].freeze

      class Error < StandardError
        attr_reader :path

        def initialize(message, path: nil)
          @path = path
          super(path ? "#{message}: #{path}" : message)
        end
      end

      class CorruptRecord < Error; end
      class UnsupportedVersion < Error; end
      class InconsistentRecord < Error; end
      class RecordNotFound < Error; end
      class StaleClaim < Error; end

      DISCOVERY_ATTEMPT_KIND = "discovery_claim".freeze
      ACTIVE_CLAIM_STATES = %w[claimed running].freeze

      attr_reader :project_root, :root

      def initialize(project_root)
        @project_root = File.expand_path(project_root)
        @root = File.join(@project_root, ".hive-state", "refactor_patrol", "v2")
      end

      # Intake is the only bridge from an immutable PR manifest to the
      # authoritative lifecycle aggregate. The per-job lock makes duplicate
      # watcher/reconciler producers preserve the first policy snapshot and
      # timestamp instead of racing two otherwise equivalent queued writes.
      def enqueue_manifest!(manifest, policy:, now: Time.now, dry_run: false)
        data = json_copy(manifest)
        source = source_from_manifest(data)
        aggregate = queued_aggregate(
          job_id: data.fetch("job_id"),
          source: source,
          policy: json_copy(policy),
          now: now
        )
        validate_job!(aggregate)
        return aggregate if dry_run

        path = job_path(aggregate.fetch("job_id"))
        FileUtils.mkdir_p(File.dirname(path))
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          if File.file?(path)
            existing = read_job(aggregate.fetch("job_id"))
            unless existing.fetch("source") == source
              quarantine_job_source!(
                aggregate.fetch("job_id"),
                authoritative: existing.fetch("source"),
                candidate: source
              )
              raise InconsistentRecord.new("refactor patrol intake source is immutable", path: path)
            end
            return existing
          end

          atomic_write(path, aggregate)
        end
        aggregate
      rescue KeyError => e
        raise CorruptRecord, "refactor patrol manifest is missing #{e.key.inspect}"
      end

      # Expose independently due intake jobs so one old backoff-bound
      # occurrence cannot hide later work.
      def eligible_jobs(now: Time.now)
        eligible_from(jobs, now: now).sort_by { |aggregate| scheduling_key(aggregate) }
      rescue ArgumentError => e
        raise InconsistentRecord, "refactor patrol job has invalid scheduling timestamp (#{e.message})"
      end

      def eligible_from(records, now:)
        records.select do |aggregate|
          next false if aggregate.fetch("complete")
          next false unless %w[queued blocked].include?(aggregate.fetch("state"))
          next false if aggregate.fetch("actions").any?

          deadline = aggregate.fetch("attempts").reverse_each.filter_map { |attempt| attempt["next_eligible_at"] }.first
          deadline.nil? || Time.iso8601(deadline) <= now
        end
      end
      private :eligible_from

      # Includes an expired analyzing claim so a restarted daemon can prove
      # the prior process group gone (or terminate it) before fencing a new
      # generation. The claim CAS remains authoritative.
      def claimable_jobs(now: Time.now)
        records = jobs
        (eligible_from(records, now: now) + records.select do |aggregate|
          next false unless aggregate.fetch("state") == "analyzing"

          attempt = active_discovery_attempt(aggregate)
          attempt && Time.iso8601(attempt.fetch("expires_at")) <= now
        end).uniq { |aggregate| aggregate.fetch("job_id") }
          .sort_by { |aggregate| scheduling_key(aggregate) }
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol claim has invalid scheduling evidence (#{e.message})"
      end

      # Action scheduling is intentionally separate from discovery scheduling:
      # an action-blocked job must never be sent back through read-only review.
      def actionable_jobs(now: Time.now)
        jobs.select do |aggregate|
          next false if aggregate.fetch("complete")
          next false unless %w[classified acting blocked].include?(aggregate.fetch("state"))
          next true if aggregate.fetch("state") == "classified" && aggregate.fetch("actions").empty?

          actions = aggregate.fetch("actions")
          active = actions.filter_map { |action| active_action_claim(action) }.first
          next Time.iso8601(active.fetch("expires_at")) <= now if active

          actions.any? do |action|
            next false if action.fetch("terminal")
            if action.fetch("owner_job_id") != aggregate.fetch("job_id")
              next linked_action_ready?(action)
            end

            !action_backoff_active?(action, now)
          end
        end.sort_by { |aggregate| scheduling_key(aggregate) }
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol action has invalid scheduling evidence (#{e.message})"
      end

      def claim_discovery!(job_id, owner:, analysis_sha:, now: Time.now, lease_sec: 3600,
                           claim_resolver: nil, owner_pid: nil, owner_process_start_time: nil)
        mutate_job(job_id) do |aggregate, path|
          return nil if aggregate.fetch("complete")

          active = active_discovery_attempt(aggregate)
          if active
            return nil if Time.iso8601(active.fetch("expires_at")) > now
            resolved = begin
              claim_resolver&.call(json_copy(active))
            rescue StandardError
              :unresolved
            end
            return nil unless resolved == :resolved

            active["state"] = "superseded"
            active["finished_at"] = now.utc.iso8601
            active["outcome"] = "expired_claim_resolved"
          end

          pinned = aggregate["analysis_sha"]
          if pinned && pinned != analysis_sha.to_s
            raise InconsistentRecord.new("refactor patrol analysis checkout changed after pin", path: path)
          end
          generation = aggregate.fetch("attempts").filter_map { |attempt| attempt["generation"] }.max.to_i + 1
          timestamp = now.utc.iso8601
          attempt = {
            "kind" => DISCOVERY_ATTEMPT_KIND,
            "owner" => owner.to_s,
            "owner_pid" => owner_pid,
            "owner_process_start_time" => owner_process_start_time,
            "generation" => generation,
            "state" => "claimed",
            "claimed_at" => timestamp,
            "heartbeat_at" => timestamp,
            "expires_at" => (now + lease_sec.to_i).utc.iso8601,
            "pid" => nil,
            "process_start_time" => nil,
            "pgid" => nil,
            "finished_at" => nil,
            "outcome" => nil,
            "next_eligible_at" => nil
          }
          aggregate["analysis_sha"] ||= analysis_sha.to_s
          aggregate["state"] = "analyzing"
          aggregate["complete"] = false
          aggregate.fetch("attempts") << attempt
          aggregate["updated_at"] = timestamp
          [ aggregate, claim_token(aggregate, attempt) ]
        end
      end

      def attach_discovery_process!(token, pid:, process_start_time:, pgid:, now: Time.now)
        mutate_claim(token) do |aggregate, attempt|
          if pid.to_i <= 1 || pgid.to_i <= 1 || process_start_time.to_s.empty?
            raise InconsistentRecord, "refactor patrol child identity is incomplete"
          end
          attempt["state"] = "running"
          attempt["pid"] = pid.to_i
          attempt["process_start_time"] = process_start_time.to_s
          attempt["pgid"] = pgid.to_i
          attempt["heartbeat_at"] = now.utc.iso8601
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      def release_discovery!(token, reason:, now: Time.now, backoff_sec: 60)
        mutate_claim(token) do |aggregate, attempt|
          timestamp = now.utc.iso8601
          attempt["state"] = "released"
          attempt["finished_at"] = timestamp
          attempt["outcome"] = reason.to_s
          attempt["next_eligible_at"] = (now + backoff_sec.to_i).utc.iso8601
          aggregate["state"] = "blocked"
          aggregate["complete"] = false
          aggregate["review_errors"] = []
          aggregate["zero_reason"] = nil
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      # Checkout/identity failures before a claim still need durable evidence
      # and retry throttling; otherwise the daemon would repeat shell/network
      # probes and identical log lines on every fast tick.
      def block_discovery!(job_id, reason:, evidence: {}, now: Time.now, backoff_sec: 60)
        mutate_job(job_id) do |aggregate, _path|
          next aggregate if aggregate.fetch("complete")

          timestamp = now.utc.iso8601
          aggregate.fetch("attempts") << {
            "kind" => "discovery_block",
            "state" => "blocked",
            "reason" => reason.to_s,
            "evidence" => json_copy(evidence),
            "finished_at" => timestamp,
            "next_eligible_at" => (now + backoff_sec.to_i).utc.iso8601
          }
          aggregate["state"] = "blocked"
          aggregate["complete"] = false
          aggregate["updated_at"] = timestamp
          aggregate
        end
      end

      def checkpoint_discovery!(token, envelope:, now: Time.now)
        payload = json_copy(envelope)
        mutate_claim(token) do |aggregate, attempt|
          assert_matching_discovery_payload!(aggregate, payload)
          aggregate["dispositions"] = DISPOSITIONS.to_h { |name| [ name, payload.fetch(name) ] }
          aggregate["feature_results"] = []
          aggregate["review_errors"] = []
          aggregate["zero_reason"] = payload.fetch("zero_reason")
          terminal = !action_authorized_for?(aggregate, payload)
          aggregate["state"] = terminal ? "complete" : "classified"
          aggregate["complete"] = terminal
          attempt["state"] = "complete"
          attempt["finished_at"] = now.utc.iso8601
          attempt["outcome"] = terminal ? "complete" : "classified"
          attempt["next_eligible_at"] = nil
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      # Canonical action ids are deliberately opaque: incorporating a digest
      # keeps repository names, family ids, and fingerprints out of filesystem
      # paths while still binding all three identity dimensions.
      def canonical_action_id(repository:, kind:, identity:)
        normalized_repository = repository.to_s.strip.downcase
        unless normalized_repository.match?(%r{\A[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*\z})
          raise InconsistentRecord, "canonical action repository must be an owner/name identity"
        end
        action_kind = kind.to_s
        unless ACTION_KINDS.include?(action_kind)
          raise InconsistentRecord, "canonical action kind must be one of #{ACTION_KINDS.inspect}"
        end
        action_identity = identity.to_s.strip
        raise InconsistentRecord, "canonical action identity must be non-empty" if action_identity.empty?

        payload = [ normalized_repository, action_kind, action_identity ]
        "#{action_kind}-#{::Digest::SHA256.hexdigest(JSON.generate(payload))}"
      end

      # Classification is immutable. This transition snapshots only the action
      # set derived by the caller after semantic-family resolution. Repeating
      # the exact snapshot is idempotent; attempts to add authority later fail.
      def initialize_actions!(job_id, specifications:, now: Time.now)
        specs = json_copy(specifications)
        unless specs.is_a?(Array) && specs.all? { |item| item.is_a?(Hash) }
          raise CorruptRecord, "action specifications must be an array of objects"
        end

        with_action_catalog_lock do
          mutate_job(job_id) do |aggregate, path|
            normalized = normalize_action_specifications(aggregate, specs, path)
            existing = aggregate.fetch("actions")
            if existing.any?
              unless initialized_action_identity(existing) == initialized_action_identity(normalized)
                raise InconsistentRecord.new("refactor patrol action snapshot is immutable", path: path)
              end

              next aggregate
            end
            if aggregate.fetch("complete")
              if normalized.any?
                raise InconsistentRecord.new("complete job cannot gain actions without explicit replay", path: path)
              end

              next aggregate
            end

            timestamp = now.utc.iso8601
            aggregate["actions"] = normalized.map do |specification|
              initialized_action(aggregate, specification, timestamp)
            end
            recompute_parent_state!(aggregate)
            aggregate["updated_at"] = timestamp
            aggregate
          end
        end
      end

      # One active fenced claim exists per canonical action. An expired claim
      # is not replaced until the caller supplies liveness evidence that the
      # previous worker has been resolved.
      def claim_action!(job_id, canonical_action_id, owner:, now: Time.now, lease_sec: 3600,
                        claim_resolver: nil, owner_pid: nil, owner_process_start_time: nil,
                        authority: true)
        raise InconsistentRecord, "action claim owner must be non-empty" if owner.to_s.empty?
        unless lease_sec.is_a?(Integer) && lease_sec.positive?
          raise InconsistentRecord, "action claim lease_sec must be a positive integer"
        end

        mutate_job(job_id) do |aggregate, path|
          return nil if aggregate.fetch("complete")

          action = find_action!(aggregate, canonical_action_id, path)
          return nil if action.fetch("terminal")
          return nil if another_action_active?(aggregate, action)
          unless action.fetch("owner_job_id") == aggregate.fetch("job_id")
            raise InconsistentRecord.new("linked canonical action must be reconciled from its owner", path: path)
          end

          claims = action["claims"] ||= []
          active = active_action_claim(action)
          if active
            return nil if Time.iso8601(active.fetch("expires_at")) > now

            resolved = begin
              claim_resolver&.call(json_copy(active))
            rescue StandardError
              :unresolved
            end
            return nil unless resolved == :resolved

            finish_claim!(active, state: "superseded", outcome: "expired_claim_resolved", now: now)
          elsif action_backoff_active?(action, now)
            return nil
          end

          continuation_only = authority != true
          if continuation_only && !continuation_after_revocation?(action)
            action["outcome"] = "authority_revoked"
            action["updated_at"] = now.utc.iso8601 if action.key?("updated_at")
            aggregate["state"] = "blocked"
            aggregate["updated_at"] = now.utc.iso8601
            next [ aggregate, nil ]
          end

          generation = claims.filter_map { |claim| claim["generation"] }.max.to_i + 1
          timestamp = now.utc.iso8601
          claim = {
            "owner" => owner.to_s,
            "owner_pid" => owner_pid,
            "owner_process_start_time" => owner_process_start_time,
            "generation" => generation,
            "state" => "claimed",
            "authority" => continuation_only ? "continuation_only" : "full",
            "claimed_at" => timestamp,
            "heartbeat_at" => timestamp,
            "expires_at" => (now + lease_sec.to_i).utc.iso8601,
            "pid" => nil,
            "process_start_time" => nil,
            "pgid" => nil,
            "finished_at" => nil,
            "outcome" => nil,
            "next_eligible_at" => nil
          }
          claims << claim
          action["outcome"] = "claimed" unless continuation_only
          action["updated_at"] = timestamp if action.key?("updated_at")
          aggregate["state"] = "acting"
          aggregate["updated_at"] = timestamp
          [ aggregate, action_claim_token(aggregate, action, claim) ]
        end
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol action claim has invalid evidence (#{e.message})"
      end

      def attach_action_process!(token, pid:, process_start_time:, pgid:, now: Time.now)
        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          if pid.to_i <= 1 || pgid.to_i <= 1 || process_start_time.to_s.empty?
            raise InconsistentRecord, "refactor patrol action child identity is incomplete"
          end

          claim["state"] = "running"
          claim["pid"] = pid.to_i
          claim["process_start_time"] = process_start_time.to_s
          claim["pgid"] = pgid.to_i
          claim["heartbeat_at"] = now.utc.iso8601
          touch_action!(aggregate, action, now)
        end
      end

      # Last-moment fence for an external transition. This intentionally
      # performs no state mutation; holding the aggregate lock while checking
      # the active generation proves a superseded worker cannot proceed.
      def assert_action_claim!(token, now: Time.now)
        mutate_action_claim(token, now: now) do |aggregate, _action, _claim|
          aggregate
        end
        true
      end

      # The durable creation intent is write-once and must precede the remote
      # request. Retrying the same payload returns the authoritative aggregate;
      # a different payload is a conflicting external transaction.
      def record_creation_intent!(token, intent:, now: Time.now)
        payload = json_copy(intent)
        unless payload.is_a?(Hash) && payload.any?
          raise CorruptRecord, "refactor patrol creation intent must be a non-empty object"
        end

        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          existing = action.fetch("receipts")["creation_intent"]
          if claim.fetch("authority") == "continuation_only"
            unless existing && existing["payload"] == payload
              raise InconsistentRecord, "revoked action claim cannot create a new remote intent"
            end
            next aggregate
          end
          if existing
            unless existing["payload"] == payload
              raise InconsistentRecord, "refactor patrol creation intent is immutable"
            end
            next aggregate
          end

          action.fetch("receipts")["creation_intent"] = {
            "payload" => payload,
            "recorded_at" => now.utc.iso8601
          }
          touch_action!(aggregate, action, now)
        end
      end
      alias record_action_intent! record_creation_intent!

      def record_action_receipt!(token, key:, value:, now: Time.now)
        receipt_key = key.to_s
        if receipt_key.empty? || receipt_key == "creation_intent"
          raise InconsistentRecord, "action receipt key is invalid"
        end

        record_action_receipts!(token, receipts: { receipt_key => value }, now: now)
      end

      def record_action_receipts!(token, receipts:, now: Time.now)
        additions = json_copy(receipts)
        unless additions.is_a?(Hash) && additions.keys.all? { |key| key.is_a?(String) && !key.empty? }
          raise CorruptRecord, "action receipts must be an object with non-empty string keys"
        end
        if additions.key?("creation_intent")
          raise InconsistentRecord, "creation intent requires record_creation_intent!"
        end

        mutate_action_claim(token, now: now) do |aggregate, action, _claim|
          changed = merge_receipts!(action.fetch("receipts"), additions)
          changed ? touch_action!(aggregate, action, now) : aggregate
        end
      end

      def record_patch_receipt!(token, receipt:, now: Time.now)
        payload = json_copy(receipt)
        mutate_action_claim(token, now: now) do |aggregate, action, _claim|
          receipts = action.fetch("receipts")
          patch_keys = receipts.keys.grep(/\Apatch(?:_\d+)?\z/).sort_by do |key|
            key == "patch" ? 1 : key.delete_prefix("patch_").to_i
          end
          next aggregate if patch_keys.any? { |key| receipts.fetch(key) == payload }

          sequence = patch_keys.empty? ? 1 : patch_keys.map do |key|
            key == "patch" ? 1 : key.delete_prefix("patch_").to_i
          end.max + 1
          key = sequence == 1 ? "patch" : "patch_#{sequence}"
          receipts[key] = payload
          touch_action!(aggregate, action, now)
        end
      end

      def record_fix_receipt!(token, receipt:, now: Time.now)
        record_action_receipt!(token, key: "fix", value: receipt, now: now)
      end

      def record_action_outcome!(token, outcome:, terminal:, receipts: {}, blocked: false, now: Time.now,
                                 backoff_sec: 0)
        unless [ true, false ].include?(terminal)
          raise InconsistentRecord, "action outcome terminal must be boolean"
        end
        unless [ true, false ].include?(blocked) && !(terminal && blocked)
          raise InconsistentRecord, "action outcome blocked must be boolean and nonterminal"
        end
        if blocked && (!backoff_sec.is_a?(Integer) || backoff_sec.negative?)
          raise InconsistentRecord, "action outcome backoff_sec must be a non-negative integer"
        end
        outcome_value = outcome.to_s
        raise InconsistentRecord, "action outcome must be non-empty" if outcome_value.empty?
        additions = json_copy(receipts)
        raise CorruptRecord, "action outcome receipts must be an object" unless additions.is_a?(Hash)

        mutate_action_claim(token, now: now) do |aggregate, action, claim|
          normalize_creation_intent_receipt!(action.fetch("receipts"), additions)
          merge_receipts!(action.fetch("receipts"), additions)
          action["outcome"] = outcome_value
          action["terminal"] = terminal
          if terminal
            finish_claim!(claim, state: "complete", outcome: outcome_value, now: now)
          elsif blocked
            finish_claim!(
              claim,
              state: "released",
              outcome: outcome_value,
              now: now,
              next_eligible_at: (now + backoff_sec.to_i).utc.iso8601
            )
          end
          touch_action!(aggregate, action, now)
          recompute_parent_state!(aggregate)
          aggregate
        end
      end

      def finish_action!(token, outcome:, receipts: {}, now: Time.now)
        record_action_outcome!(token, outcome: outcome, terminal: true, receipts: receipts, now: now)
      end

      def release_action!(token, outcome:, receipts: {}, now: Time.now, backoff_sec: 60)
        record_action_outcome!(
          token,
          outcome: outcome,
          terminal: false,
          receipts: receipts,
          blocked: true,
          now: now,
          backoff_sec: backoff_sec
        )
      end

      # A linked occurrence owns no receipts. It may atomically copy only the
      # owner's terminal proof so its parent can settle without duplicating an
      # external effect.
      def reconcile_linked_action!(job_id, canonical_action_id, now: Time.now)
        mutate_job(job_id) do |aggregate, path|
          action = find_action!(aggregate, canonical_action_id, path)
          next aggregate if action.fetch("terminal")
          if action.fetch("owner_job_id") == aggregate.fetch("job_id")
            raise InconsistentRecord.new("owner action cannot be reconciled as a link", path: path)
          end

          owner = read_job(action.fetch("owner_job_id"))
          owner_action = find_action!(owner, canonical_action_id, job_path(owner.fetch("job_id")))
          next aggregate unless owner_action.fetch("terminal")

          action["outcome"] = owner_action.fetch("outcome")
          action["terminal"] = true
          action["updated_at"] = now.utc.iso8601 if action.key?("updated_at")
          recompute_parent_state!(aggregate)
          aggregate["updated_at"] = now.utc.iso8601
          aggregate
        end
      end

      def write_job!(aggregate, dry_run: false)
        data = json_copy(aggregate)
        validate_job!(data)
        return data if dry_run

        path = job_path(data.fetch("job_id"))
        FileUtils.mkdir_p(File.dirname(path))
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          if File.exist?(path)
            existing = read_job(data.fetch("job_id"))
            validate_transition!(existing, data, path)
            return existing if existing == data
          end
          atomic_write(path, data)
        end
        data
      end

      def read_job(job_id)
        id = validate_id!(job_id)
        path = job_path(id)
        raise RecordNotFound.new("refactor patrol job not found", path: path) unless File.file?(path)

        read_job_path(path, expected_job_id: id)
      end

      def jobs
        each_job.to_a
      end

      def each_job
        return enum_for(__method__) unless block_given?
        return unless Dir.exist?(jobs_dir)

        Dir.glob(File.join(jobs_dir, "*.json")).sort.each do |path|
          yield read_job_path(path, expected_job_id: File.basename(path, ".json"))
        end
      end

      def rebuild_indexes!
        fingerprint_entries = {}
        owner_actions = {}
        action_links = []

        each_job do |aggregate|
          next unless aggregate.fetch("complete") == true

          job_id = aggregate.fetch("job_id")
          DISPOSITIONS.each do |disposition|
            aggregate.fetch("dispositions").fetch(disposition).each do |item|
              fingerprint = item.fetch("fingerprint")
              entry = fingerprint_entries[fingerprint] ||= {
                "occurrences" => [],
                "canonical_action_ids" => []
              }
              entry.fetch("occurrences") << {
                "job_id" => job_id,
                "thesis_id" => item.fetch("id"),
                "disposition" => disposition
              }
            end
          end

          aggregate.fetch("actions").select { |action| action.fetch("terminal") == true }.each do |action|
            action_id = action.fetch("canonical_action_id")
            if action.fetch("owner_job_id") == job_id
              if owner_actions.key?(action_id)
                raise InconsistentRecord, "canonical action #{action_id.inspect} has multiple owner jobs"
              end
              owner_actions[action_id] = {
                "owner_job_id" => job_id,
                "kind" => action.fetch("kind"),
                "thesis_fingerprint" => action.fetch("thesis_fingerprint"),
                "outcome" => action.fetch("outcome")
              }
            else
              action_links << [ action_id, action.fetch("owner_job_id") ]
            end

            fingerprint_entries[action.fetch("thesis_fingerprint")] ||= {
              "occurrences" => [],
              "canonical_action_ids" => []
            }
            fingerprint_entries.fetch(action.fetch("thesis_fingerprint"))
                               .fetch("canonical_action_ids") << action_id
          end
        end

        action_links.each do |action_id, owner_job_id|
          owner = owner_actions[action_id]
          unless owner && owner.fetch("owner_job_id") == owner_job_id
            raise InconsistentRecord,
                  "canonical action #{action_id.inspect} links to missing owner job #{owner_job_id.inspect}"
          end
        end

        fingerprint_entries.each_value do |entry|
          entry.fetch("occurrences").sort_by! { |item| [ item.fetch("job_id"), item.fetch("thesis_id") ] }
          entry["canonical_action_ids"] = entry.fetch("canonical_action_ids").uniq.sort
        end
        fingerprints = {
          "schema" => "hive-refactor-patrol-fingerprint-index",
          "schema_version" => SCHEMA_VERSION,
          "fingerprints" => fingerprint_entries.sort.to_h
        }
        actions = {
          "schema" => "hive-refactor-patrol-action-index",
          "schema_version" => SCHEMA_VERSION,
          "actions" => owner_actions.sort.to_h
        }
        atomic_write(fingerprint_index_path, fingerprints)
        atomic_write(action_index_path, actions)
        { "fingerprints" => fingerprints, "actions" => actions }
      end

      def fingerprint_index
        read_derived_index(
          fingerprint_index_path,
          schema: "hive-refactor-patrol-fingerprint-index",
          collection: "fingerprints"
        ) { rebuild_indexes!.fetch("fingerprints") }
      end

      def action_index
        read_derived_index(
          action_index_path,
          schema: "hive-refactor-patrol-action-index",
          collection: "actions"
        ) { rebuild_indexes!.fetch("actions") }
      end

      def fingerprint_index_path
        File.join(root, "indexes", "fingerprints.json")
      end

      def action_index_path
        File.join(root, "indexes", "actions.json")
      end

      private

      def with_action_catalog_lock
        FileUtils.mkdir_p(root)
        path = File.join(root, "actions.lock")
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def normalize_action_specifications(aggregate, specifications, path)
        unless %w[classified acting blocked complete].include?(aggregate.fetch("state"))
          raise InconsistentRecord.new("job must be classified before actions are initialized", path: path)
        end

        dispositions = disposition_by_id(aggregate.fetch("dispositions"))
        normalized = specifications.map do |specification|
          strict_hash!(
            specification,
            required: %w[thesis_id kind],
            allowed: %w[thesis_id kind family_id],
            label: "action specification",
            path: path
          )
          thesis_id = specification.fetch("thesis_id").to_s
          kind = specification.fetch("kind").to_s
          entry = dispositions[thesis_id]
          raise InconsistentRecord.new("action thesis is not classified", path: path) unless entry

          disposition, thesis = entry
          validate_action_authority!(aggregate, kind, disposition, thesis, path)
          family_id = specification["family_id"].to_s unless specification["family_id"].nil?
          identity = action_identity(kind, family_id, thesis, path)
          {
            "canonical_action_id" => canonical_action_id(
              repository: aggregate.dig("source", "repository"),
              kind: kind,
              identity: identity
            ),
            "thesis_id" => thesis_id,
            "thesis_fingerprint" => thesis.fetch("fingerprint"),
            "kind" => kind
          }.tap do |item|
            item["family_id"] = family_id unless family_id.to_s.empty?
          end
        end

        normalized.group_by { |item| item.fetch("canonical_action_id") }.values.map do |duplicates|
          duplicates.min_by { |item| item.fetch("thesis_id") }
        end.sort_by { |item| item.fetch("canonical_action_id") }
      end

      def validate_action_authority!(aggregate, kind, disposition, thesis, path)
        unless ACTION_KINDS.include?(kind)
          raise InconsistentRecord.new("action kind must be one of #{ACTION_KINDS.inspect}", path: path)
        end
        policy = aggregate.fetch("policy")
        case kind
        when "fix"
          unless disposition == "accepted" && policy.fetch("auto_fix")
            raise InconsistentRecord.new("fix action exceeds the immutable policy/disposition snapshot", path: path)
          end
        when "issue"
          eligible = (disposition == "flagged" && thesis.fetch("admissible")) || disposition == "accepted"
          unless eligible && policy.fetch("issue_filing")
            raise InconsistentRecord.new("issue action exceeds the immutable policy/disposition snapshot", path: path)
          end
        end
      end

      def action_identity(kind, family_id, thesis, path)
        return thesis.fetch("fingerprint") unless kind == "issue"
        if family_id.to_s.empty?
          raise InconsistentRecord.new("issue action requires a semantic family_id", path: path)
        end

        family_id
      end

      def initialized_action_identity(actions)
        actions.map do |action|
          action.slice(
            "canonical_action_id", "thesis_id", "thesis_fingerprint", "kind", "family_id"
          ).compact
        end.sort_by { |action| action.fetch("canonical_action_id") }
      end

      def initialized_action(aggregate, specification, timestamp)
        owner_action = canonical_owner_action(specification.fetch("canonical_action_id"))
        owner_job_id = owner_action ? owner_action.fetch("owner_job_id") : aggregate.fetch("job_id")
        linked = owner_job_id != aggregate.fetch("job_id")
        {
          "canonical_action_id" => specification.fetch("canonical_action_id"),
          "thesis_id" => specification.fetch("thesis_id"),
          "thesis_fingerprint" => specification.fetch("thesis_fingerprint"),
          "kind" => specification.fetch("kind"),
          "owner_job_id" => owner_job_id,
          "outcome" => linked ? owner_action.fetch("outcome") : "queued",
          "terminal" => linked && owner_action.fetch("terminal"),
          "receipts" => {},
          "claims" => [],
          "created_at" => timestamp,
          "updated_at" => timestamp
        }.tap do |action|
          action["family_id"] = specification.fetch("family_id") if specification.key?("family_id")
        end
      end

      def canonical_owner_action(action_id)
        matches = each_job.flat_map do |aggregate|
          aggregate.fetch("actions").filter_map do |action|
            next unless action.fetch("canonical_action_id") == action_id
            next unless action.fetch("owner_job_id") == aggregate.fetch("job_id")

            action
          end
        end
        if matches.size > 1
          raise InconsistentRecord, "canonical action #{action_id.inspect} has multiple owner jobs"
        end

        matches.first
      end

      def find_action!(aggregate, canonical_action_id, path)
        id = canonical_action_id.to_s
        action = aggregate.fetch("actions").find { |candidate| candidate.fetch("canonical_action_id") == id }
        raise RecordNotFound.new("refactor patrol action not found", path: path) unless action

        action
      end

      def active_action_claim(action)
        Array(action["claims"]).reverse_each.find do |claim|
          ACTIVE_ACTION_CLAIM_STATES.include?(claim["state"])
        end
      end

      def another_action_active?(aggregate, selected)
        aggregate.fetch("actions").any? do |action|
          action != selected && active_action_claim(action)
        end
      end

      def action_backoff_active?(action, now)
        deadline = Array(action["claims"]).last&.fetch("next_eligible_at", nil)
        deadline && Time.iso8601(deadline) > now
      end

      def continuation_after_revocation?(action)
        receipts = action.fetch("receipts")
        receipts.key?("creation_intent") || receipts.key?("pr") || receipts.key?("pr_url") ||
          receipts.key?("issue") || receipts.key?("issue_url") ||
          action.fetch("outcome").match?(/remote_outcome_unknown|pr_opened|handoff|merged/)
      end

      def linked_action_ready?(action)
        owner = read_job(action.fetch("owner_job_id"))
        owner_action = owner.fetch("actions").find do |candidate|
          candidate.fetch("canonical_action_id") == action.fetch("canonical_action_id")
        end
        owner_action&.fetch("terminal") == true
      end

      def action_claim_token(aggregate, action, claim)
        {
          job_id: aggregate.fetch("job_id"),
          canonical_action_id: action.fetch("canonical_action_id"),
          owner: claim.fetch("owner"),
          generation: claim.fetch("generation"),
          continuation_only: claim.fetch("authority") == "continuation_only"
        }
      end

      def mutate_action_claim(token, now:)
        mutate_job(token.fetch(:job_id)) do |aggregate, path|
          action = find_action!(aggregate, token.fetch(:canonical_action_id), path)
          claim = active_action_claim(action)
          unless claim && claim["owner"] == token.fetch(:owner).to_s &&
                 claim["generation"] == token.fetch(:generation).to_i
            raise StaleClaim.new("refactor patrol action claim fence is stale", path: path)
          end
          if Time.iso8601(claim.fetch("expires_at")) <= now
            raise StaleClaim.new("refactor patrol action claim lease expired", path: path)
          end

          yield aggregate, action, claim
        end
      rescue ArgumentError, KeyError => e
        raise InconsistentRecord, "refactor patrol action claim has invalid evidence (#{e.message})"
      end

      def finish_claim!(claim, state:, outcome:, now:, next_eligible_at: nil)
        timestamp = now.utc.iso8601
        claim["state"] = state
        claim["heartbeat_at"] = timestamp
        claim["finished_at"] = timestamp
        claim["outcome"] = outcome
        claim["next_eligible_at"] = next_eligible_at
      end

      def touch_action!(aggregate, action, now)
        timestamp = now.utc.iso8601
        action["updated_at"] = timestamp if action.key?("updated_at")
        aggregate["updated_at"] = timestamp
        aggregate
      end

      def merge_receipts!(receipts, additions)
        changed = false
        additions.each do |key, value|
          if receipts.key?(key)
            unless receipts.fetch(key) == value
              raise InconsistentRecord, "action receipt #{key.inspect} is immutable"
            end
            next
          end

          receipts[key] = value
          changed = true
        end
        changed
      end

      def normalize_creation_intent_receipt!(receipts, additions)
        return unless additions.key?("creation_intent")

        existing = receipts["creation_intent"]
        unless existing && (additions.fetch("creation_intent") == true || additions.fetch("creation_intent") == existing)
          raise InconsistentRecord, "creation intent must be recorded before an action outcome"
        end

        additions.delete("creation_intent")
      end

      def recompute_parent_state!(aggregate)
        actions = aggregate.fetch("actions")
        complete = actions.empty? || actions.all? { |action| action.fetch("terminal") }
        aggregate["complete"] = complete
        aggregate["state"] =
          if complete
            "complete"
          elsif actions.any? { |action| blocked_action?(action) }
            "blocked"
          else
            "acting"
          end
        aggregate
      end

      def blocked_action?(action)
        return false if action.fetch("terminal")
        return true if action.fetch("outcome") == "authority_revoked"

        Array(action["claims"]).last&.fetch("state", nil) == "released"
      end

      def scheduling_key(aggregate)
        source = aggregate.fetch("source")
        merged_at = source["merged_at"] ? Time.iso8601(source.fetch("merged_at")).utc : Time.at(0).utc
        [ merged_at, source.fetch("number"), source.fetch("merge_sha"), aggregate.fetch("job_id") ]
      end

      def active_discovery_attempt(aggregate)
        aggregate.fetch("attempts").reverse_each.find do |attempt|
          attempt["kind"] == DISCOVERY_ATTEMPT_KIND && ACTIVE_CLAIM_STATES.include?(attempt["state"])
        end
      end

      def claim_token(aggregate, attempt)
        {
          job_id: aggregate.fetch("job_id"), owner: attempt.fetch("owner"),
          generation: attempt.fetch("generation")
        }
      end

      def mutate_claim(token)
        mutate_job(token.fetch(:job_id)) do |aggregate, path|
          attempt = active_discovery_attempt(aggregate)
          unless attempt && attempt["owner"] == token.fetch(:owner).to_s &&
                 attempt["generation"] == token.fetch(:generation).to_i
            raise StaleClaim.new("refactor patrol claim fence is stale", path: path)
          end
          yield aggregate, attempt
        end
      end

      def mutate_job(job_id)
        path = job_path(validate_id!(job_id))
        FileUtils.mkdir_p(File.dirname(path))
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          existing = read_job(job_id)
          aggregate = json_copy(existing)
          result = yield aggregate, path
          replacement, return_value = result.is_a?(Array) ? result : [ result, result ]
          validate_job!(replacement, path: path)
          validate_transition!(existing, replacement, path, action_api: true)
          return return_value if replacement == existing

          atomic_write(path, replacement)
          return return_value
        end
      end

      def assert_matching_discovery_payload!(aggregate, payload)
        unless payload.is_a?(Hash) && payload["schema"] == "hive-refactor-patrol" &&
               payload["schema_version"] == SCHEMA_VERSION && payload["ok"] == true &&
               payload["complete"] == true && payload["job_id"] == aggregate.fetch("job_id") &&
               payload["project"] == aggregate.dig("source", "registration") &&
               payload["project_root"] == project_root && payload["dry_run"] == false &&
               payload["analysis_sha"] == aggregate.fetch("analysis_sha") &&
               payload["source_pr"] == aggregate.fetch("source") &&
               payload["review_errors"] == [] && payload["attempts"] == [] && payload["actions"] == []
          raise InconsistentRecord, "refactor patrol completion payload does not match its claimed job"
        end
        DISPOSITIONS.each { |name| payload.fetch(name) }
        payload.fetch("zero_reason")
      rescue KeyError => e
        raise InconsistentRecord, "refactor patrol completion payload is missing #{e.key.inspect}"
      end

      def action_authorized_for?(aggregate, payload)
        policy = aggregate.fetch("policy")
        (policy.fetch("auto_fix") && payload.fetch("accepted").any?) ||
          (policy.fetch("issue_filing") && payload.fetch("flagged").any? { |item| item["admissible"] == true })
      end

      def source_from_manifest(manifest)
        unless manifest.is_a?(Hash) && manifest["schema"] == PrManifest::SCHEMA &&
               manifest["schema_version"] == PrManifest::SCHEMA_VERSION
          raise CorruptRecord, "refactor patrol intake requires a v2 PR manifest"
        end

        source = manifest.fetch("source")
        %w[url number repository registration base_branch base_sha merge_sha merged_at].each do |key|
          source.fetch(key)
        end
        source.merge(
          "changed_paths" => manifest.fetch("changed_paths"),
          "manifest_checksum" => manifest.fetch("manifest_checksum")
        )
      end

      def queued_aggregate(job_id:, source:, policy:, now:)
        timestamp = now.utc.iso8601
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "job_id" => job_id,
          "source" => source,
          "analysis_sha" => nil,
          "policy" => policy,
          "state" => "queued",
          "complete" => false,
          "dispositions" => DISPOSITIONS.to_h { |name| [ name, [] ] },
          "feature_results" => [],
          "review_errors" => [],
          "zero_reason" => nil,
          "attempts" => [],
          "actions" => [],
          "created_at" => timestamp,
          "updated_at" => timestamp
        }
      end

      def quarantine_job_source!(job_id, authoritative:, candidate:)
        directory = File.join(root, "quarantine", "jobs")
        digest = ::Digest::SHA256.hexdigest(JSON.generate(candidate.sort.to_h))
        path = File.join(directory, "#{job_id}-#{digest}.json")
        return path if File.file?(path)

        evidence = {
          "schema" => "hive-refactor-patrol-job-intake-conflict",
          "schema_version" => 1,
          "job_id" => job_id,
          "reason" => "divergent_job_source",
          "authoritative_source" => authoritative,
          "candidate_source" => candidate
        }
        atomic_write(path, evidence)
      end

      def jobs_dir
        File.join(root, "jobs")
      end

      def job_path(job_id)
        File.join(jobs_dir, "#{validate_id!(job_id)}.json")
      end

      def validate_id!(job_id)
        id = job_id.to_s
        raise InconsistentRecord, "invalid refactor patrol job id #{id.inspect}" unless id.match?(ID_PATTERN)

        id
      end

      def read_job_path(path, expected_job_id:)
        data = JSON.parse(File.read(path))
        raise CorruptRecord.new("refactor patrol job must contain a JSON object", path: path) unless data.is_a?(Hash)

        version = data["schema_version"]
        unless version.is_a?(Integer)
          raise CorruptRecord.new("refactor patrol job has no integer schema_version", path: path)
        end
        if version != SCHEMA_VERSION
          raise UnsupportedVersion.new("unsupported refactor patrol job schema_version #{version}", path: path)
        end

        validate_job!(data, path: path)
        unless data.fetch("job_id") == expected_job_id
          raise InconsistentRecord.new(
            "refactor patrol job id #{data.fetch('job_id').inspect} does not match filename #{expected_job_id.inspect}",
            path: path
          )
        end
        data
      rescue JSON::ParserError, EncodingError, SystemCallError, IOError => e
        raise CorruptRecord.new("cannot read refactor patrol job (#{e.class}: #{e.message})", path: path)
      end

      def validate_job!(data, path: nil)
        strict_hash!(data, required: TOP_LEVEL_KEYS, allowed: TOP_LEVEL_KEYS, label: "job", path: path)
        inconsistent!("unexpected job schema", path) unless data.fetch("schema") == SCHEMA
        version = data.fetch("schema_version")
        unless version.is_a?(Integer)
          raise CorruptRecord.new("job schema_version must be an integer", path: path)
        end
        if version != SCHEMA_VERSION
          raise UnsupportedVersion.new("unsupported refactor patrol job schema_version #{version}", path: path)
        end
        validate_id!(data.fetch("job_id"))
        inconsistent!("job state is invalid", path) unless STATES.include?(data.fetch("state"))
        inconsistent!("job complete must be boolean", path) unless [ true, false ].include?(data.fetch("complete"))
        if data.fetch("complete") != (data.fetch("state") == "complete")
          inconsistent!("job state and complete flag disagree", path)
        end

        validate_source!(data.fetch("source"), path)
        validate_policy!(data.fetch("policy"), path)
        string_or_nil!(data.fetch("analysis_sha"), "analysis_sha", path)
        timestamp!(data.fetch("created_at"), "created_at", path)
        timestamp!(data.fetch("updated_at"), "updated_at", path)

        errors = array_of_hashes!(data.fetch("review_errors"), "review_errors", path)
        inconsistent!("complete job cannot retain review errors", path) if data.fetch("complete") && errors.any?
        zero_reason = data.fetch("zero_reason")
        unless zero_reason.nil? || ZERO_REASONS.include?(zero_reason)
          inconsistent!("zero_reason is invalid", path)
        end
        inconsistent!("partial job cannot have zero_reason", path) if !data.fetch("complete") && zero_reason

        dispositions = data.fetch("dispositions")
        strict_hash!(dispositions, required: DISPOSITIONS, allowed: DISPOSITIONS, label: "dispositions", path: path)
        seen_ids = {}
        fingerprint_by_id = {}
        DISPOSITIONS.each do |name|
          array_of_hashes!(dispositions.fetch(name), "#{name} dispositions", path).each do |item|
            validate_disposition!(item, name, path)
            id = item.fetch("id")
            inconsistent!("thesis #{id.inspect} appears in multiple dispositions", path) if seen_ids[id]
            seen_ids[id] = name
            fingerprint_by_id[id] = item.fetch("fingerprint")
          end
        end
        if data.fetch("complete") && seen_ids.empty? && zero_reason.nil?
          inconsistent!("complete zero-thesis job requires zero_reason", path)
        end

        array_of_hashes!(data.fetch("feature_results"), "feature_results", path).each do |item|
          strict_hash!(item, required: FEATURE_RESULT_KEYS, allowed: FEATURE_RESULT_KEYS,
                             label: "feature result", path: path)
          nonempty_string!(item.fetch("feature_id"), "feature result id", path)
          inconsistent!("feature result complete must be boolean", path) unless [ true, false ].include?(item.fetch("complete"))
          string_array!(item.fetch("thesis_ids"), "feature result thesis_ids", path)
          array_of_hashes!(item.fetch("errors"), "feature result errors", path)
        end
        array_of_hashes!(data.fetch("attempts"), "attempts", path)
        actions = data.fetch("actions")
        validate_actions!(actions, data.fetch("job_id"), fingerprint_by_id, path)
        if actions.sum { |action| active_action_claim(action) ? 1 : 0 } > 1
          inconsistent!("job can serialize only one active action claim", path)
        end
        if actions.any? && data.fetch("complete") != actions.all? { |action| action.fetch("terminal") }
          inconsistent!("job completion must match terminal action snapshot", path)
        end
        data
      rescue KeyError => e
        raise CorruptRecord.new("refactor patrol job is missing #{e.key.inspect}", path: path)
      end

      def validate_source!(source, path)
        strict_hash!(source, required: %w[url number repository registration base_branch base_sha merge_sha],
                            allowed: SOURCE_KEYS, label: "source", path: path)
        %w[url repository registration base_branch base_sha merge_sha].each do |key|
          nonempty_string!(source.fetch(key), "source #{key}", path)
        end
        inconsistent!("source number must be a positive integer", path) unless source.fetch("number").is_a?(Integer) && source.fetch("number").positive?
        string_array!(source["changed_paths"], "source changed_paths", path) if source.key?("changed_paths")
        timestamp!(source["merged_at"], "source merged_at", path) if source.key?("merged_at")
        nonempty_string!(source["manifest_checksum"], "source manifest_checksum", path) if source.key?("manifest_checksum")
      end

      def validate_policy!(policy, path)
        strict_hash!(policy, required: %w[discovery auto_fix issue_filing], allowed: POLICY_KEYS,
                             label: "policy", path: path)
        %w[discovery auto_fix issue_filing].each do |key|
          inconsistent!("policy #{key} must be boolean", path) unless [ true, false ].include?(policy.fetch(key))
        end
        validate_action_policy!(policy.fetch("action"), path) if policy.key?("action")
        if policy.key?("epoch") && !policy.fetch("epoch").to_s.match?(/\A[a-f0-9]{64}\z/)
          inconsistent!("policy epoch must be a SHA-256 digest", path)
        end
        timestamp!(policy["captured_at"], "policy captured_at", path) if policy.key?("captured_at")
      end

      def validate_action_policy!(action, path)
        strict_hash!(
          action,
          required: POLICY_ACTION_KEYS,
          allowed: POLICY_ACTION_KEYS,
          label: "policy action",
          path: path
        )
        %w[default_branch auto_fix_agent].each do |key|
          nonempty_string!(action.fetch(key), "policy action #{key}", path)
        end
        unless %w[low medium high].include?(action.fetch("min_confidence"))
          inconsistent!("policy action min_confidence is invalid", path)
        end

        commands = action.fetch("commands")
        strict_hash!(
          commands,
          required: POLICY_COMMAND_KEYS,
          allowed: POLICY_COMMAND_KEYS,
          label: "policy action commands",
          path: path
        )
        commands.each do |key, value|
          next if value.nil? || (value.is_a?(String) && !value.strip.empty?)

          inconsistent!("policy action command #{key} must be null or non-empty", path)
        end

        caps = action.fetch("caps")
        strict_hash!(
          caps,
          required: POLICY_CAP_KEYS,
          allowed: POLICY_CAP_KEYS,
          label: "policy action caps",
          path: path
        )
        %w[single_feature_only allow_dependency_bumps allow_public_api_changes allow_cross_feature].each do |key|
          inconsistent!("policy action cap #{key} must be boolean", path) unless [ true, false ].include?(caps.fetch(key))
        end
        %w[max_files max_diff_lines].each do |key|
          value = caps.fetch(key)
          inconsistent!("policy action cap #{key} must be positive", path) unless value.is_a?(Integer) && value.positive?
        end
        score = action.fetch("issue_min_leverage_score")
        unless score.is_a?(Numeric) && score.between?(0, 1)
          inconsistent!("policy action issue_min_leverage_score must be between 0 and 1", path)
        end
      end

      def validate_disposition!(item, name, path)
        strict_hash!(item, required: %w[id feature_id fingerprint score admissible reasons],
                           allowed: DISPOSITION_KEYS, label: "#{name} disposition", path: path)
        %w[id feature_id fingerprint].each { |key| nonempty_string!(item.fetch(key), "disposition #{key}", path) }
        inconsistent!("disposition score must be numeric", path) unless item.fetch("score").is_a?(Numeric)
        inconsistent!("disposition admissible must be boolean", path) unless [ true, false ].include?(item.fetch("admissible"))
        reasons = string_array!(item.fetch("reasons"), "disposition reasons", path)
        if name == "accepted"
          inconsistent!("accepted disposition cannot have reasons", path) unless reasons.empty?
          inconsistent!("accepted disposition must be admissible", path) unless item.fetch("admissible")
        else
          inconsistent!("#{name} disposition requires reasons", path) if reasons.empty?
        end
        nonempty_string!(item["reference"], "disposition reference", path) if item.key?("reference")
        nonempty_string!(item["family_id"], "disposition family_id", path) if item.key?("family_id")
        validate_thesis_snapshot!(item, path) if item.key?("thesis")
      end

      def validate_thesis_snapshot!(disposition, path)
        thesis = disposition.fetch("thesis")
        unless thesis.is_a?(Hash)
          raise CorruptRecord.new("disposition thesis must be an object", path: path)
        end
        %w[id feature_id fingerprint].each do |key|
          nonempty_string!(thesis[key], "disposition thesis #{key}", path)
        end
        unless thesis.fetch("id") == disposition.fetch("id") &&
               thesis.fetch("feature_id") == disposition.fetch("feature_id") &&
               thesis.fetch("fingerprint") == disposition.fetch("fingerprint")
          inconsistent!("disposition thesis identity does not match its classification", path)
        end
        Thesis.from_h(thesis)
      rescue KeyError, ArgumentError => e
        raise CorruptRecord.new("disposition thesis snapshot is incomplete (#{e.message})", path: path)
      end

      def validate_actions!(actions, job_id, fingerprint_by_id, path)
        seen = {}
        array_of_hashes!(actions, "actions", path).each do |action|
          strict_hash!(action, required: ACTION_REQUIRED_KEYS, allowed: ACTION_KEYS, label: "action", path: path)
          %w[canonical_action_id thesis_id thesis_fingerprint kind owner_job_id outcome].each do |key|
            nonempty_string!(action.fetch(key), "action #{key}", path)
          end
          validate_id!(action.fetch("canonical_action_id"))
          inconsistent!("action kind is invalid", path) unless ACTION_KINDS.include?(action.fetch("kind"))
          inconsistent!("action terminal must be boolean", path) unless [ true, false ].include?(action.fetch("terminal"))
          inconsistent!("action receipts must be an object", path) unless action.fetch("receipts").is_a?(Hash)
          validate_action_claims!(action, path)
          timestamp!(action.fetch("created_at"), "action created_at", path) if action.key?("created_at")
          timestamp!(action.fetch("updated_at"), "action updated_at", path) if action.key?("updated_at")
          nonempty_string!(action.fetch("family_id"), "action family_id", path) if action.key?("family_id")
          id = action.fetch("canonical_action_id")
          inconsistent!("duplicate canonical action #{id.inspect}", path) if seen[id]
          seen[id] = true
          expected_fingerprint = fingerprint_by_id[action.fetch("thesis_id")]
          unless expected_fingerprint == action.fetch("thesis_fingerprint")
            inconsistent!("action thesis identity is not present in this job", path)
          end
          if action.fetch("owner_job_id") != job_id && !action.fetch("receipts").empty?
            inconsistent!("linked canonical action #{id.inspect} cannot duplicate owner receipts", path)
          end
          if action.fetch("owner_job_id") != job_id && Array(action["claims"]).any?
            inconsistent!("linked canonical action #{id.inspect} cannot own claims", path)
          end
        end
      end

      def validate_action_claims!(action, path)
        return unless action.key?("claims")

        generations = []
        active = 0
        array_of_hashes!(action.fetch("claims"), "action claims", path).each do |claim|
          strict_hash!(
            claim,
            required: ACTION_CLAIM_KEYS,
            allowed: ACTION_CLAIM_KEYS,
            label: "action claim",
            path: path
          )
          nonempty_string!(claim.fetch("owner"), "action claim owner", path)
          generation = claim.fetch("generation")
          unless generation.is_a?(Integer) && generation.positive?
            inconsistent!("action claim generation must be a positive integer", path)
          end
          generations << generation
          unless %w[claimed running released superseded complete].include?(claim.fetch("state"))
            inconsistent!("action claim state is invalid", path)
          end
          unless %w[full continuation_only].include?(claim.fetch("authority"))
            inconsistent!("action claim authority is invalid", path)
          end
          %w[claimed_at heartbeat_at expires_at].each do |key|
            timestamp!(claim.fetch(key), "action claim #{key}", path)
          end
          timestamp!(claim["finished_at"], "action claim finished_at", path) if claim["finished_at"]
          timestamp!(claim["next_eligible_at"], "action claim next_eligible_at", path) if claim["next_eligible_at"]
          validate_action_process_identity!(claim, path)
          active += 1 if ACTIVE_ACTION_CLAIM_STATES.include?(claim.fetch("state"))
        end
        inconsistent!("action claim generations must be strictly increasing", path) unless generations == generations.uniq.sort
        inconsistent!("action has multiple active claims", path) if active > 1
        inconsistent!("terminal action cannot retain an active claim", path) if action.fetch("terminal") && active.positive?
      end

      def validate_action_process_identity!(claim, path)
        owner_pid = claim.fetch("owner_pid")
        unless owner_pid.nil? || (owner_pid.is_a?(Integer) && owner_pid.positive?)
          inconsistent!("action claim owner_pid must be a positive integer or null", path)
        end
        owner_start = claim.fetch("owner_process_start_time")
        unless owner_start.nil? || (owner_start.is_a?(String) && !owner_start.empty?)
          inconsistent!("action claim owner_process_start_time must be a string or null", path)
        end

        child = [ claim.fetch("pid"), claim.fetch("process_start_time"), claim.fetch("pgid") ]
        if claim.fetch("state") == "running" || child.any?
          valid = child[0].is_a?(Integer) && child[0] > 1 &&
                  child[1].is_a?(String) && !child[1].empty? &&
                  child[2].is_a?(Integer) && child[2] > 1
          inconsistent!("action claim child identity is incomplete", path) unless valid
        end
      end

      def validate_transition!(existing, replacement, path, action_api: false)
        %w[source policy created_at].each do |key|
          next if existing.fetch(key) == replacement.fetch(key)

          inconsistent!("job #{key} is immutable", path)
        end
        if !existing.fetch("analysis_sha").to_s.empty? &&
           existing.fetch("analysis_sha") != replacement.fetch("analysis_sha")
          inconsistent!("job analysis_sha is immutable once pinned", path)
        end

        old_dispositions = disposition_by_id(existing.fetch("dispositions"))
        new_dispositions = disposition_by_id(replacement.fetch("dispositions"))
        old_dispositions.each do |id, old_value|
          unless new_dispositions[id] == old_value
            inconsistent!("analysis disposition for thesis #{id.inspect} is immutable", path)
          end
        end
        validate_action_transition!(existing.fetch("actions"), replacement.fetch("actions"), path)
        if existing.fetch("actions") != replacement.fetch("actions") && !action_api
          inconsistent!("action changes require the fenced action transition API", path)
        end
        if existing.fetch("complete") && existing != replacement
          inconsistent!("complete job aggregate is write-once", path)
        end
      end

      def validate_action_transition!(old_actions, new_actions, path)
        return if old_actions.empty?

        old_by_id = old_actions.to_h { |action| [ action.fetch("canonical_action_id"), action ] }
        new_by_id = new_actions.to_h { |action| [ action.fetch("canonical_action_id"), action ] }
        unless old_by_id.keys.sort == new_by_id.keys.sort
          inconsistent!("initialized action snapshot is immutable", path)
        end

        old_by_id.each do |action_id, old_action|
          new_action = new_by_id.fetch(action_id)
          %w[canonical_action_id thesis_id thesis_fingerprint kind owner_job_id family_id created_at].each do |key|
            next if old_action[key] == new_action[key]

            inconsistent!("canonical action #{action_id.inspect} identity is immutable", path)
          end
          old_action.fetch("receipts").each do |key, value|
            unless new_action.fetch("receipts")[key] == value
              inconsistent!("canonical action #{action_id.inspect} receipt #{key.inspect} is immutable", path)
            end
          end
          if old_action.fetch("terminal") && old_action != new_action
            inconsistent!("terminal canonical action #{action_id.inspect} is write-once", path)
          end
          validate_claim_transition!(old_action, new_action, path)
        end
      end

      def validate_claim_transition!(old_action, new_action, path)
        old_claims = Array(old_action["claims"])
        new_claims = Array(new_action["claims"])
        if new_claims.size < old_claims.size
          inconsistent!("canonical action claim history is append-only", path)
        end

        old_claims.each_with_index do |old_claim, index|
          new_claim = new_claims.fetch(index)
          if ACTIVE_ACTION_CLAIM_STATES.include?(old_claim.fetch("state"))
            validate_active_claim_transition!(old_claim, new_claim, path)
          elsif old_claim != new_claim
            inconsistent!("finished canonical action claim is immutable", path)
          end
        end
      end

      def validate_active_claim_transition!(old_claim, new_claim, path)
        immutable = %w[
          owner owner_pid owner_process_start_time generation authority claimed_at expires_at
        ]
        immutable.each do |key|
          inconsistent!("canonical action claim identity is immutable", path) unless old_claim[key] == new_claim[key]
        end
        transitions = {
          "claimed" => %w[claimed running released superseded complete],
          "running" => %w[running released superseded complete]
        }
        unless transitions.fetch(old_claim.fetch("state")).include?(new_claim.fetch("state"))
          inconsistent!("canonical action claim state cannot move backwards", path)
        end
        %w[pid process_start_time pgid finished_at outcome next_eligible_at].each do |key|
          next if old_claim[key].nil? || old_claim[key] == new_claim[key]

          inconsistent!("canonical action claim evidence is immutable once recorded", path)
        end
      end

      def disposition_by_id(dispositions)
        DISPOSITIONS.each_with_object({}) do |name, indexed|
          dispositions.fetch(name).each do |item|
            indexed[item.fetch("id")] = [ name, item ]
          end
        end
      end

      def strict_hash!(value, required:, allowed:, label:, path:)
        raise CorruptRecord.new("#{label} must be an object", path: path) unless value.is_a?(Hash)

        missing = required - value.keys
        unknown = value.keys - allowed
        raise CorruptRecord.new("#{label} is missing keys #{missing.inspect}", path: path) unless missing.empty?
        inconsistent!("#{label} has unknown keys #{unknown.inspect}", path) unless unknown.empty?
        value
      end

      def array_of_hashes!(value, label, path)
        raise CorruptRecord.new("#{label} must be an array of objects", path: path) unless value.is_a?(Array) && value.all? { |item| item.is_a?(Hash) }

        value
      end

      def string_array!(value, label, path)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
          raise CorruptRecord.new("#{label} must be an array of non-empty strings", path: path)
        end
        value
      end

      def nonempty_string!(value, label, path)
        inconsistent!("#{label} must be a non-empty string", path) unless value.is_a?(String) && !value.empty?
      end

      def string_or_nil!(value, label, path)
        inconsistent!("#{label} must be a string or null", path) unless value.nil? || value.is_a?(String)
      end

      def timestamp!(value, label, path)
        nonempty_string!(value, label, path)
        Time.iso8601(value)
      rescue ArgumentError
        inconsistent!("#{label} must be an ISO-8601 timestamp", path)
      end

      def inconsistent!(message, path)
        raise InconsistentRecord.new(message, path: path)
      end

      def read_derived_index(path, schema:, collection:)
        return yield unless File.file?(path)

        data = JSON.parse(File.read(path))
        unless data.is_a?(Hash) && data["schema"] == schema && data["schema_version"] == SCHEMA_VERSION &&
               data[collection].is_a?(Hash) && (data.keys - %w[schema schema_version] - [ collection ]).empty?
          return yield
        end
        data
      rescue JSON::ParserError, SystemCallError, IOError
        yield
      end

      def atomic_write(path, data)
        dir = File.dirname(path)
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(data)}\n", mode: 0o600)
        fsync_directory(dir)
        path
      end

      def fsync_directory(dir)
        File.open(dir, File::RDONLY) { |handle| handle.fsync }
      rescue Errno::EINVAL, Errno::ENOTSUP, Errno::EBADF
        nil
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      rescue JSON::GeneratorError, TypeError => e
        raise CorruptRecord, "refactor patrol job is not JSON serializable (#{e.message})"
      end
    end
  end
end
