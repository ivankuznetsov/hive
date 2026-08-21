require "digest"
require "json"
require "securerandom"
require "time"
require "hive/managed_directory"
require "hive/patrol_fix"
require "hive/patrol_fix/source_snapshot"
require "hive/secret_patterns"

module Hive
  module PatrolFix
    class AdmissionStore
      SCHEMA = "hive-patrol-fix-admission".freeze
      SCHEMA_VERSION = 2
      MAX_RECORD_BYTES = 512 * 1024
      MAX_RECORDS = 8_192
      MAX_CANDIDATES = 64
      MAX_CANDIDATE_BYTES = 6 * 1024
      MAX_CANDIDATE_CONTEXT_BYTES = 192 * 1024
      MAX_EVIDENCE = 64
      INVENTORY_LOCK = "inventory.lock".freeze
      OCCURRENCE_ID = /\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}\z/
      DIGEST = /\A[0-9a-f]{64}\z/
      REVISION = /\A[0-9a-f]{40}\z/
      STATUSES = %w[pending deciding decided blocked materializing bound acknowledged retry_wait].freeze
      DECISIONS = %w[same_root distinct insufficient_evidence].freeze
      CANDIDATE_KINDS = %w[task coding_task pull_request issue].freeze

      class Error < Hive::Error; end
      class Conflict < Error; end
      class CorruptRecord < Error; end
      class StaleDecision < Error; end

      attr_reader :root

      def initialize(root:)
        @root = File.expand_path(root)
        @directory = Hive::ManagedDirectory.new(root: @root, label: "Patrol-fix admission store")
      end

      def reserve!(occurrence_id:, snapshot:, now: Time.now.utc)
        id = occurrence_id!(occurrence_id)
        source = snapshot.is_a?(SourceSnapshot) ? snapshot : SourceSnapshot.parse(snapshot)
        @directory.prepare!
        @directory.with_lock(INVENTORY_LOCK) do
          if (existing = fetch(id))
            unless existing.fetch("source_digest") == source.digest &&
                   existing.fetch("source") == source.to_h
              conflict!("admission occurrence identity conflicts with different source bytes")
            end
            next existing
          end

          compact_acknowledged_for_capacity!
          mutate(id, create: true) do |record|
            if record
              unless record.fetch("source_digest") == source.digest &&
                     record.fetch("source") == source.to_h
                conflict!("admission occurrence identity conflicts with different source bytes")
              end
              next record
            end
            initial_record(id, source, now)
          end
        end
      end

      def fetch(occurrence_id)
        id = occurrence_id!(occurrence_id)
        bytes = @directory.read(record_path(id), max_bytes: MAX_RECORD_BYTES, missing: true)
        bytes && parse_record(bytes, expected_id: id)
      end

      def prepare_decision!(occurrence_id, candidates:, current_head:, inventory: nil,
                            reservation_id: nil, lease_expires_at: nil,
                            now: Time.now.utc)
        normalized = normalize_candidates(candidates)
        head = revision!(current_head, "current head")
        frozen_inventory = normalize_candidate_inventory(
          inventory || default_inventory(normalized), candidates: normalized
        )
        digest = candidate_digest(
          normalized, current_head: head, inventory: frozen_inventory
        )
        reservation = normalize_decision_reservation(
          "reservation_id" => reservation_id || SecureRandom.hex(32),
          "reserved_at" => timestamp(now),
          "expires_at" => timestamp(lease_expires_at || (now.utc + 7_200))
        )
        mutate(occurrence_id) do |record|
          terminal = %w[materializing bound acknowledged].include?(record.fetch("status"))
          conflict!("admission is already materializing or bound") if terminal
          existing = record["decision_reservation"]
          if record.fetch("status") == "deciding" && existing &&
             Time.iso8601(existing.fetch("expires_at")) > now.utc
            if existing.fetch("reservation_id") == reservation.fetch("reservation_id") &&
               record.fetch("candidate_digest") == digest
              next record
            end
            conflict!("semantic admission decision is already reserved")
          end
          record["status"] = "deciding"
          record["candidates"] = normalized
          record["candidate_inventory"] = frozen_inventory
          record["candidate_digest"] = digest
          record["current_head"] = head
          record["decision_reservation"] = reservation
          record["decision"] = nil
          record["retry"] = nil
          touch(record, now)
          record
        end
      end

      def record_decision!(occurrence_id, candidate_digest:, decision:, rationale:, evidence:,
                           model_receipt:, candidate_identity: nil, reservation_id:,
                           now: Time.now.utc)
        mutate(occurrence_id) do |record|
          unless record.fetch("status") == "deciding" &&
                 record.fetch("candidate_digest") == candidate_digest
            raise StaleDecision, "admission candidate set changed while deciding"
          end
          assert_reservation!(record, reservation_id, now: now)
          route = decision.to_s
          conflict!("semantic admission decision is invalid") unless DECISIONS.include?(route)
          identity = candidate_identity&.to_s
          if route == "same_root"
            conflict!("same_root requires a current candidate identity") if identity.to_s.empty?
            unless record.fetch("candidates").any? { |item| item.fetch("identity") == identity }
              raise StaleDecision, "admission candidate set changed while deciding"
            end
          elsif identity && !identity.empty?
            conflict!("only same_root may select a candidate identity")
          end
          decision_evidence = string_array!(evidence, "decision evidence", min: 1,
                                            max: MAX_EVIDENCE, item_max: 16 * 1024)
          decision_record = {
            "decision" => route,
            "candidate_identity" => identity,
            "rationale" => text!(rationale, "decision rationale", max: 16 * 1024),
            "evidence" => decision_evidence,
            "model_receipt" => text!(model_receipt, "model receipt", max: 4 * 1024),
            "decided_at" => timestamp(now)
          }
          reject_secret!(decision_record)
          record["decision"] = decision_record
          record["status"] = route == "insufficient_evidence" ? "blocked" : "decided"
          record["decision_reservation"] = nil
          touch(record, now)
          record
        end
      end

      def reset_stale!(occurrence_id, reservation_id:, now: Time.now.utc)
        mutate(occurrence_id) do |record|
          assert_reservation!(record, reservation_id, now: now)
          record["status"] = "pending"
          record["candidates"] = []
          record["candidate_inventory"] = nil
          record["candidate_digest"] = nil
          record["current_head"] = nil
          record["decision_reservation"] = nil
          record["decision"] = nil
          touch(record, now)
          record
        end
      end

      def reset_decided_stale!(occurrence_id, now: Time.now.utc)
        mutate(occurrence_id) do |record|
          unless record.fetch("status") == "decided" && !record["decision_reservation"]
            conflict!("only an unfenced decided admission may be reset before materialization")
          end
          record.merge!(
            "status" => "pending", "candidates" => [], "candidate_inventory" => nil,
            "candidate_digest" => nil, "current_head" => nil, "decision" => nil
          )
          touch(record, now)
          record
        end
      end

      def expire_decision!(occurrence_id, now: Time.now.utc)
        mutate(occurrence_id) do |record|
          reservation = record["decision_reservation"]
          unless record.fetch("status") == "deciding" && reservation &&
                 Time.iso8601(reservation.fetch("expires_at")) <= now.utc
            conflict!("semantic admission reservation is not expired")
          end
          record.merge!(
            "status" => "pending", "candidates" => [], "candidate_inventory" => nil,
            "candidate_digest" => nil, "current_head" => nil,
            "decision_reservation" => nil, "decision" => nil
          )
          touch(record, now)
          record
        end
      end

      def cancel_unlaunched_decision!(occurrence_id, reservation_id:, now: Time.now.utc)
        mutate(occurrence_id) do |record|
          reservation = record["decision_reservation"]
          unless record.fetch("status") == "deciding" && reservation &&
                 reservation.fetch("reservation_id") == reservation_id.to_s
            raise StaleDecision, "semantic admission reservation changed"
          end
          record.merge!(
            "status" => "pending", "candidates" => [], "candidate_inventory" => nil,
            "candidate_digest" => nil, "current_head" => nil,
            "decision_reservation" => nil, "decision" => nil
          )
          touch(record, now)
          record
        end
      end

      def record_provider_retry!(occurrence_id, reason:, error_class:, retry_at:,
                                 reservation_id:, now: Time.now.utc)
        retry_time = retry_at.utc
        conflict!("admission retry must be scheduled in the future") unless retry_time > now.utc
        mutate(occurrence_id) do |record|
          assert_reservation!(record, reservation_id, now: now)
          apply_retry!(
            record, reason: reason, error_class: error_class,
            retry_at: retry_time, now: now
          )
        end
      end

      def record_retry!(occurrence_id, reason:, error_class:, retry_at:,
                        now: Time.now.utc)
        retry_time = retry_at.utc
        conflict!("admission retry must be scheduled in the future") unless retry_time > now.utc
        mutate(occurrence_id) do |record|
          conflict!("an acknowledged admission cannot enter retry") if record["acknowledgement"]
          conflict!("reserved provider retry requires its exact reservation") if
            record["decision_reservation"]
          apply_retry!(
            record, reason: reason, error_class: error_class,
            retry_at: retry_time, now: now
          )
        end
      end

      def resume_materialization_retry!(occurrence_id, now: Time.now.utc)
        mutate(occurrence_id) do |record|
          actionable_decision = %w[same_root distinct].include?(record.dig("decision", "decision"))
          unless record.fetch("status") == "retry_wait" &&
                 (record["materialization_intent"] || actionable_decision)
            conflict!("only a deferred materialization may resume")
          end
          record["status"] = if record["task"]
            "bound"
          elsif record["materialization_intent"]
            "materializing"
          else
            "decided"
          end
          touch(record, now)
          record
        end
      end

      def visible_blocked
        each_record.select { |record| record.fetch("status") == "blocked" }.freeze
      end

      def with_materialization_lock(&block)
        @directory.with_lock("materialization.lock", &block)
      end

      def begin_materialization!(occurrence_id, intent:, now: Time.now.utc)
        normalized = normalize_materialization_intent(intent)
        mutate(occurrence_id) do |record|
          existing = record["materialization_intent"]
          if existing
            conflict!("materialization intent conflicts") unless existing == normalized
            next record
          end
          unless record.fetch("status") == "decided"
            conflict!("only an identity-decided admission may materialize")
          end
          record["materialization_intent"] = normalized
          record["status"] = "materializing"
          touch(record, now)
          record
        end
      end

      def bind_task!(occurrence_id, task:, now: Time.now.utc)
        normalized = normalize_task_binding(task)
        mutate(occurrence_id) do |record|
          unless record["materialization_intent"]
            conflict!("task binding requires a durable materialization intent")
          end
          if record["task"]
            conflict!("task binding conflicts") unless record["task"] == normalized
            next record
          end
          record["task"] = normalized
          record["status"] = "bound"
          record["retry"] = nil
          touch(record, now)
          record
        end
      end

      def acknowledge!(occurrence_id, now: Time.now.utc)
        mutate(occurrence_id) do |record|
          conflict!("admission acknowledgement requires an exact task binding") unless record["task"]
          acknowledgement = {
            "receipt_id" => acknowledgement_receipt(record),
            "acknowledged_at" => timestamp(now)
          }
          if record["acknowledgement"]
            existing = record.fetch("acknowledgement")
            conflict!("admission acknowledgement conflicts") unless
              existing.fetch("receipt_id") == acknowledgement.fetch("receipt_id")
            next record
          end
          record["acknowledgement"] = acknowledgement
          record["status"] = "acknowledged"
          record["retry"] = nil
          touch(record, now)
          record
        end
      end

      def prior_source_evidence(task_slug:, engine:, identity:)
        matches = each_record.select do |record|
          record.dig("task", "slug") == task_slug.to_s &&
            record.dig("source", "engine") == engine.to_s &&
            record.dig("source", "identity") == identity.to_s &&
            %w[bound acknowledged].include?(record.fetch("status"))
        end
        matches.max_by { |record| record.dig("task", "generation") || 0 }
               &.fetch("evidence_digest")
      end

      def pending(now: Time.now.utc, limit: 64)
        max = Integer(limit)
        raise ArgumentError, "admission limit must be between 1 and 64" unless (1..64).cover?(max)
        each_record.select do |record|
          status = record.fetch("status")
          if status == "deciding"
            expires_at = record.dig("decision_reservation", "expires_at")
            next expires_at && Time.iso8601(expires_at) <= now
          end
          next true if %w[pending decided materializing bound].include?(status)

          retry_at = record.dig("retry", "retry_at")
          status == "retry_wait" && retry_at && Time.iso8601(retry_at) <= now
        end.first(max).freeze
      end

      def candidate_digest(candidates, current_head:, inventory: nil)
        normalized = normalize_candidates(candidates)
        head = revision!(current_head, "current head")
        frozen_inventory = normalize_candidate_inventory(
          inventory || default_inventory(normalized), candidates: normalized
        )
        Digest::SHA256.hexdigest(PatrolFix.canonical_json(
          "current_head" => head,
          "inventory" => frozen_inventory,
          "candidates" => normalized
        ))
      end

      private

      def compact_acknowledged_for_capacity!
        names = @directory.each_child("records", missing: true).to_a.filter_map do |name|
          next if name.end_with?(".lock")
          match = /\A(.+)\.json\z/.match(name)
          corrupt!("admission inventory contains an unknown entry") unless match
          [ name, match[1] ]
        end
        required = names.length - MAX_RECORDS + 1
        return if required <= 0

        removable = names.filter_map do |name, id|
          relative = File.join("records", name)
          bytes = @directory.read(relative, max_bytes: MAX_RECORD_BYTES)
          record = parse_record(bytes, expected_id: id)
          next unless record.fetch("status") == "acknowledged"

          [ record.dig("acknowledgement", "acknowledged_at"), record.fetch("created_at"), name, bytes ]
        end.sort
        if removable.length < required
          conflict!("admission capacity contains active work")
        end
        removable.first(required).each do |_acknowledged_at, _created_at, name, bytes|
          @directory.unlink(
            File.join("records", name),
            expected_digest: Digest::SHA256.hexdigest(bytes), max_bytes: MAX_RECORD_BYTES
          )
        end
      end

      def initial_record(id, snapshot, now)
        time = timestamp(now)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "occurrence_id" => id,
          "source" => snapshot.to_h,
          "source_digest" => snapshot.digest,
          "evidence_digest" => snapshot.evidence_digest,
          "status" => "pending",
          "candidates" => [],
          "candidate_inventory" => nil,
          "candidate_digest" => nil,
          "current_head" => nil,
          "decision_reservation" => nil,
          "decision" => nil,
          "materialization_intent" => nil,
          "task" => nil,
          "acknowledgement" => nil,
          "retry" => nil,
          "created_at" => time,
          "updated_at" => time
        }
      end

      def each_record
        records = []
        @directory.each_child("records", missing: true) do |name|
          next if name.end_with?(".lock")
          match = /\A(.+)\.json\z/.match(name)
          corrupt!("admission inventory contains an unknown entry") unless match
          records << match[1]
          corrupt!("admission inventory exceeds the bounded limit") if records.length > MAX_RECORDS
        end
        records.sort.map { |id| fetch(id) }
      end

      def mutate(occurrence_id, create: false)
        id = occurrence_id!(occurrence_id)
        @directory.with_lock(File.join("records", "#{id}.lock")) do
          relative = record_path(id)
          original = @directory.read(relative, max_bytes: MAX_RECORD_BYTES, missing: true)
          record = original && parse_record(original, expected_id: id)
          conflict!("admission occurrence is missing") unless record || create
          replacement = yield(record && PatrolFix.deep_copy(record))
          validate_record!(replacement, expected_id: id)
          bytes = PatrolFix.canonical_json(replacement)
          corrupt!("admission record exceeds the size limit") if bytes.bytesize > MAX_RECORD_BYTES
          next replacement if bytes == original
          @directory.atomic_write(
            relative, bytes, mode: 0o600,
            expected_digest: original && Digest::SHA256.hexdigest(original),
            max_existing_bytes: MAX_RECORD_BYTES
          )
          PatrolFix.deep_freeze(replacement)
        end
      rescue Hive::ManagedDirectory::UnsafeError => e
        corrupt!(e.message)
      end

      def parse_record(bytes, expected_id:)
        record = JSON.parse(bytes)
        corrupt!("admission record is not canonical") unless
          PatrolFix.canonical_json(record).b == bytes.b
        validate_record!(record, expected_id: expected_id)
      rescue JSON::ParserError, EncodingError
        corrupt!("admission record is malformed")
      end

      def validate_record!(record, expected_id:)
        unless record.is_a?(Hash) && record.keys.sort == %w[
          acknowledgement candidate_digest candidate_inventory candidates created_at
          current_head decision decision_reservation evidence_digest materialization_intent
          occurrence_id retry schema schema_version source source_digest status task updated_at
        ].sort
          corrupt!("admission record fields are invalid")
        end
        corrupt!("admission record schema is unsupported") unless
          record["schema"] == SCHEMA && record["schema_version"] == SCHEMA_VERSION
        corrupt!("admission occurrence identity changed") unless record["occurrence_id"] == expected_id
        snapshot = SourceSnapshot.new(record.fetch("source"))
        source_digest = digest!(record.fetch("source_digest"), "source digest")
        evidence_digest = digest!(record.fetch("evidence_digest"), "evidence digest")
        corrupt!("admission source digest does not match its snapshot") unless
          source_digest == snapshot.digest
        corrupt!("admission evidence digest does not match its snapshot") unless
          evidence_digest == snapshot.evidence_digest
        corrupt!("admission status is invalid") unless STATUSES.include?(record["status"])
        candidates = normalize_candidates(record.fetch("candidates"))
        corrupt!("admission candidates are not canonical") unless
          candidates == record.fetch("candidates")
        candidate_digest = digest!(record["candidate_digest"], "candidate digest", optional: true)
        inventory = record["candidate_inventory"] &&
          normalize_candidate_inventory(
            record.fetch("candidate_inventory"), candidates: candidates
          )
        current_head = revision!(record["current_head"], "current head", optional: true)
        if candidate_digest || inventory || current_head
          corrupt!("admission candidate snapshot is incomplete") unless
            candidate_digest && inventory && current_head
          expected = self.candidate_digest(
            candidates, current_head: current_head, inventory: inventory
          )
          corrupt!("admission candidate digest does not match its snapshot") unless
            candidate_digest == expected
        end
        reservation = record["decision_reservation"] &&
          normalize_decision_reservation(record.fetch("decision_reservation"))
        validate_decision!(record["decision"], candidates: candidates) if record["decision"]
        normalize_materialization_intent(record["materialization_intent"]) if record["materialization_intent"]
        normalize_task_binding(record["task"]) if record["task"]
        validate_acknowledgement!(record["acknowledgement"], record: record) if
          record["acknowledgement"]
        validate_retry!(record["retry"]) if record["retry"]
        validate_state_invariants!(record, reservation: reservation)
        timestamp_value!(record.fetch("created_at"), "created_at")
        timestamp_value!(record.fetch("updated_at"), "updated_at")
        PatrolFix.deep_freeze(record)
      rescue SourceSnapshot::InvalidSnapshot => e
        corrupt!(e.message)
      end

      def normalize_candidates(candidates)
        list = Array(candidates)
        conflict!("candidate set exceeds #{MAX_CANDIDATES} entries") if list.length > MAX_CANDIDATES
        normalized = list.map.with_index do |candidate, index|
          unless candidate.is_a?(Hash)
            conflict!("candidate #{index} fields are invalid")
          end
          minimal_keys = %w[evidence_digest identity kind target_revision]
          rich_keys = %w[
            affected_code context_digest evidence evidence_digest identity kind
            manifest_digest remediation target_revision
          ]
          unless [ minimal_keys.sort, rich_keys.sort ].include?(candidate.keys.sort)
            conflict!("candidate #{index} fields are invalid")
          end
          kind = candidate.fetch("kind").to_s
          conflict!("candidate #{index} kind is invalid") unless CANDIDATE_KINDS.include?(kind)
          core = {
            "kind" => kind,
            "identity" => text!(candidate.fetch("identity"), "candidate identity", max: 2_048),
            "evidence_digest" => digest!(candidate.fetch("evidence_digest"), "candidate evidence digest"),
            "target_revision" => revision!(candidate.fetch("target_revision"), "candidate target revision")
          }
          next core if candidate.keys.sort == minimal_keys.sort

          rich = core.merge(
            "manifest_digest" => digest!(
              candidate.fetch("manifest_digest"), "candidate manifest digest"
            ),
            "evidence" => string_array!(
              candidate.fetch("evidence"), "candidate evidence",
              min: 1, max: 3, item_max: 768
            ),
            "affected_code" => string_array!(
              candidate.fetch("affected_code"), "candidate affected code",
              min: 1, max: 12, item_max: 256
            ),
            "remediation" => text!(
              candidate.fetch("remediation"), "candidate remediation", max: 1_536
            )
          )
          context_digest = digest!(
            candidate.fetch("context_digest"), "candidate context digest"
          )
          expected = Digest::SHA256.hexdigest(PatrolFix.canonical_json(rich))
          conflict!("candidate context digest does not match its bytes") unless
            context_digest == expected
          rich["context_digest"] = context_digest
          conflict!("candidate context exceeds its byte limit") if
            PatrolFix.canonical_json(rich).bytesize > MAX_CANDIDATE_BYTES
          rich
        end
        normalized = normalized.sort_by do |candidate|
          [ candidate.fetch("kind"), candidate.fetch("identity") ]
        end
        conflict!("candidate context exceeds its aggregate byte limit") if
          PatrolFix.canonical_json(normalized).bytesize > MAX_CANDIDATE_CONTEXT_BYTES
        normalized
      end

      def default_inventory(candidates)
        digest = Digest::SHA256.hexdigest(PatrolFix.canonical_json(candidates))
        {
          "count" => candidates.length,
          "digest" => digest,
          "context_digest" => digest,
          "truncated" => false
        }
      end

      def normalize_candidate_inventory(inventory, candidates:)
        unless inventory.is_a?(Hash) && inventory.keys.sort == %w[
          context_digest count digest truncated
        ]
          conflict!("candidate inventory fields are invalid")
        end
        count = Integer(inventory.fetch("count"))
        conflict!("candidate inventory count is invalid") unless
          count.between?(0, MAX_RECORDS)
        truncated = inventory.fetch("truncated")
        conflict!("candidate inventory truncation is invalid") unless
          truncated == true || truncated == false
        conflict!("candidate inventory count is smaller than its selected context") if
          count < candidates.length
        conflict!("candidate inventory truncation conflicts with selected context") if
          truncated != (count > candidates.length)
        context_digest = digest!(
          inventory.fetch("context_digest"), "candidate context digest"
        )
        expected_context_digest = Digest::SHA256.hexdigest(
          PatrolFix.canonical_json(candidates)
        )
        conflict!("candidate context digest does not match selected bytes") unless
          context_digest == expected_context_digest
        {
          "count" => count,
          "digest" => digest!(inventory.fetch("digest"), "candidate inventory digest"),
          "context_digest" => context_digest,
          "truncated" => truncated
        }
      rescue ArgumentError, TypeError
        conflict!("candidate inventory count is invalid")
      end

      def normalize_decision_reservation(reservation)
        unless reservation.is_a?(Hash) && reservation.keys.sort == %w[
          expires_at reservation_id reserved_at
        ]
          conflict!("semantic admission reservation fields are invalid")
        end
        normalized = {
          "reservation_id" => digest!(
            reservation.fetch("reservation_id"), "semantic admission reservation id"
          ),
          "reserved_at" => timestamp_value!(
            reservation.fetch("reserved_at"), "semantic admission reserved_at"
          ).utc.iso8601,
          "expires_at" => timestamp_value!(
            reservation.fetch("expires_at"), "semantic admission expires_at"
          ).utc.iso8601
        }
        conflict!("semantic admission reservation expiry is invalid") unless
          Time.iso8601(normalized.fetch("expires_at")) >
          Time.iso8601(normalized.fetch("reserved_at"))
        normalized
      end

      def assert_reservation!(record, reservation_id, now:)
        reservation = record["decision_reservation"]
        unless reservation &&
               reservation.fetch("reservation_id") == reservation_id.to_s
          raise StaleDecision, "semantic admission reservation changed"
        end
        if Time.iso8601(reservation.fetch("expires_at")) <= now.utc
          raise StaleDecision, "semantic admission reservation expired"
        end
      end

      def apply_retry!(record, reason:, error_class:, retry_at:, now:)
        attempts = record.dig("retry", "attempts").to_i + 1
        record["retry"] = {
          "attempts" => attempts,
          "reason" => text!(reason.to_s, "retry reason", max: 256),
          "error_class" => text!(error_class.to_s, "retry error class", max: 256),
          "retry_at" => timestamp(retry_at)
        }
        record["status"] = "retry_wait"
        record["decision_reservation"] = nil
        touch(record, now)
        record
      end

      def normalize_materialization_intent(intent)
        unless intent.is_a?(Hash) && intent.keys.sort == %w[
          evidence_digest generation idempotency_key input_fingerprint slug
        ]
          conflict!("materialization intent fields are invalid")
        end
        {
          "idempotency_key" => text!(intent.fetch("idempotency_key"), "materialization idempotency key", max: 512),
          "input_fingerprint" => digest!(intent.fetch("input_fingerprint"), "materialization input fingerprint"),
          "slug" => text!(intent.fetch("slug"), "materialization slug", max: 64),
          "generation" => positive_integer!(intent.fetch("generation"), "materialization generation"),
          "evidence_digest" => digest!(intent.fetch("evidence_digest"), "materialization evidence digest")
        }
      end

      def validate_decision!(decision, candidates:)
        unless decision.is_a?(Hash) && decision.keys.sort == %w[
          candidate_identity decided_at decision evidence model_receipt rationale
        ].sort
          corrupt!("admission decision fields are invalid")
        end
        route = decision.fetch("decision")
        corrupt!("admission decision is invalid") unless DECISIONS.include?(route)
        identity = decision["candidate_identity"]
        if route == "same_root"
          text!(identity, "candidate identity", max: 2_048)
          corrupt!("admission decision candidate is absent") unless
            candidates.any? { |candidate| candidate.fetch("identity") == identity }
        elsif !identity.nil?
          corrupt!("non-matching admission decision selected a candidate")
        end
        text!(decision.fetch("rationale"), "decision rationale", max: 16 * 1024)
        string_array!(decision.fetch("evidence"), "decision evidence", min: 1,
                      max: MAX_EVIDENCE, item_max: 16 * 1024)
        text!(decision.fetch("model_receipt"), "model receipt", max: 4 * 1024)
        timestamp_value!(decision.fetch("decided_at"), "decided_at")
        reject_secret!(decision)
      end

      def validate_state_invariants!(record, reservation:)
        status = record.fetch("status")
        decision = record["decision"]
        intent = record["materialization_intent"]
        task = record["task"]
        acknowledgement = record["acknowledgement"]

        if status == "deciding"
          corrupt!("deciding admission lacks an exact reservation") unless reservation
        elsif reservation
          corrupt!("non-deciding admission retains a decision reservation")
        end

        if %w[decided blocked materializing bound acknowledged].include?(status)
          corrupt!("admission state lacks a decision") unless decision
        end
        if status == "blocked"
          corrupt!("blocked admission lacks insufficient-evidence decision") unless
            decision&.fetch("decision") == "insufficient_evidence"
        elsif decision&.fetch("decision") == "insufficient_evidence"
          corrupt!("insufficient-evidence admission has an actionable state")
        end
        if %w[materializing bound acknowledged].include?(status)
          corrupt!("materializing admission lacks durable intent") unless intent
        end
        if %w[bound acknowledged].include?(status)
          corrupt!("bound admission lacks task identity") unless task
        end
        corrupt!("admission acknowledgement lacks task identity") if acknowledgement && !task
        corrupt!("acknowledged admission lacks a receipt") if
          status == "acknowledged" && !acknowledgement
        corrupt!("non-acknowledged admission has a receipt") if
          status != "acknowledged" && acknowledgement
        if task && intent
          intended = intent.slice("slug", "generation", "evidence_digest")
          corrupt!("admission task binding conflicts with materialization intent") unless
            task == intended
        end
      end

      def normalize_task_binding(task)
        unless task.is_a?(Hash) && task.keys.sort == %w[evidence_digest generation slug]
          conflict!("task binding fields are invalid")
        end
        {
          "slug" => text!(task.fetch("slug"), "task slug", max: 64),
          "generation" => positive_integer!(task.fetch("generation"), "task generation"),
          "evidence_digest" => digest!(task.fetch("evidence_digest"), "task evidence digest")
        }
      end

      def validate_acknowledgement!(acknowledgement, record:)
        unless acknowledgement.is_a?(Hash) && acknowledgement.keys.sort ==
               %w[acknowledged_at receipt_id]
          corrupt!("admission acknowledgement fields are invalid")
        end
        receipt = text!(
          acknowledgement.fetch("receipt_id"), "admission acknowledgement receipt", max: 128
        )
        corrupt!("admission acknowledgement receipt is inconsistent") unless
          receipt == acknowledgement_receipt(record)
        timestamp_value!(acknowledgement.fetch("acknowledged_at"), "acknowledged_at")
      end

      def acknowledgement_receipt(record)
        digest = Digest::SHA256.hexdigest(PatrolFix.canonical_json(
          "occurrence_id" => record.fetch("occurrence_id"),
          "source_digest" => record.fetch("source_digest"),
          "task" => record.fetch("task")
        ))
        "admission:#{digest}"
      end

      def validate_retry!(retry_record)
        unless retry_record.is_a?(Hash) && retry_record.keys.sort ==
               %w[attempts error_class reason retry_at]
          corrupt!("admission retry fields are invalid")
        end
        positive_integer!(retry_record.fetch("attempts"), "retry attempts")
        text!(retry_record.fetch("reason"), "retry reason", max: 256)
        text!(retry_record.fetch("error_class"), "retry error class", max: 256)
        timestamp_value!(retry_record.fetch("retry_at"), "retry_at")
      end

      def record_path(id) = File.join("records", "#{id}.json")

      def occurrence_id!(value)
        id = value.to_s
        conflict!("admission occurrence identity is invalid") unless id.match?(OCCURRENCE_ID)
        id
      end

      def digest!(value, label, optional: false)
        return nil if optional && value.nil?
        corrupt!("#{label} is invalid") unless value.is_a?(String) && value.match?(DIGEST)
        value
      end

      def revision!(value, label, optional: false)
        return nil if optional && value.nil?
        conflict!("#{label} is invalid") unless value.is_a?(String) && value.match?(REVISION)
        value
      end

      def text!(value, label, max:)
        conflict!("#{label} is invalid") unless value.is_a?(String) && !value.empty? &&
          value.bytesize <= max && !value.match?(/[\u0000-\u001f\u007f]/)
        value
      end

      def string_array!(value, label, min:, max:, item_max:)
        conflict!("#{label} is invalid") unless value.is_a?(Array) &&
          value.length.between?(min, max)
        value.map { |entry| text!(entry, label, max: item_max) }
      end

      def positive_integer!(value, label)
        conflict!("#{label} is invalid") unless value.is_a?(Integer) && value.positive?
        value
      end

      def timestamp(value) = value.utc.iso8601

      def timestamp_value!(value, label)
        time = Time.iso8601(value.to_s)
        corrupt!("#{label} must be UTC") unless time.utc? && value.end_with?("Z")
        time
      rescue ArgumentError
        corrupt!("#{label} is invalid")
      end

      def touch(record, now) = record["updated_at"] = timestamp(now)

      def reject_secret!(value)
        conflict!("admission decision contains secret-like material") if
          Hive::SecretPatterns.match?(PatrolFix.canonical_json(value))
      end

      def conflict!(message)
        raise Conflict, Hive::SecretPatterns.redact(message.to_s)[0, 512]
      end

      def corrupt!(message)
        raise CorruptRecord, Hive::SecretPatterns.redact(message.to_s)[0, 512]
      end
    end
  end
end
