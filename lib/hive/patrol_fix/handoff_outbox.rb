require "digest"
require "json"
require "time"
require "hive/managed_directory"
require "hive/patrol_fix"
require "hive/patrol_fix/cutover_gate"
require "hive/patrol_fix/source_snapshot"
require "hive/secret_patterns"

module Hive
  module PatrolFix
    # Storage primitive embedded by a source adapter. Its files live below the
    # source namespace and its acknowledgement is therefore source-owned; the
    # admission store receives immutable snapshots but cannot mutate this queue.
    class HandoffOutbox
      SCHEMA = "hive-patrol-fix-source-outbox".freeze
      SCHEMA_VERSION = 1
      MAX_RECORD_BYTES = 512 * 1024
      MAX_RECORDS = 8_192
      DIGEST = /\A[0-9a-f]{64}\z/
      SLUG = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/

      class Error < Hive::Error; end
      class Conflict < Error; end
      class CorruptRecord < Error; end

      attr_reader :source

      def initialize(root:, source:, gate: CutoverGate.new)
        @source = source.to_s
        raise ArgumentError, "source outbox identity is invalid" unless SourceSnapshot::ENGINES.include?(@source)

        @gate = gate
        @directory = Hive::ManagedDirectory.new(
          root: File.expand_path(root), label: "#{@source} Patrol Fix outbox"
        )
      end

      def enabled? = @gate.enabled?

      def publish!(occurrence_id:, snapshot:, now: Time.now.utc)
        return nil unless enabled?

        source_snapshot = snapshot.is_a?(SourceSnapshot) ? snapshot : SourceSnapshot.new(snapshot)
        conflict!("snapshot source does not match outbox") unless source_snapshot.to_h.fetch("engine") == source
        id = text!(occurrence_id, "occurrence identity", max: 256)
        candidate = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "source" => source,
          "source_epoch" => @gate.epoch,
          "occurrence_id" => id,
          "snapshot" => source_snapshot.to_h,
          "snapshot_digest" => source_snapshot.digest,
          "status" => "pending",
          "retry_at" => nil,
          "acknowledgement" => nil,
          "created_at" => timestamp(now),
          "updated_at" => timestamp(now)
        }
        mutate(id, create: true) do |existing|
          if existing
            immutable = %w[source source_epoch occurrence_id snapshot snapshot_digest]
            conflict!("source outbox occurrence conflicts") unless
              existing.slice(*immutable) == candidate.slice(*immutable)
            next existing
          end
          candidate
        end
      end

      def fetch(occurrence_id)
        id = text!(occurrence_id, "occurrence identity", max: 256)
        bytes = @directory.read(record_path(id), max_bytes: MAX_RECORD_BYTES, missing: true)
        bytes && parse_record(bytes, expected_id: id)
      rescue Hive::ManagedDirectory::UnsafeError => e
        corrupt!(e.message)
      end

      def pending(limit: 64, now: Time.now.utc)
        return [].freeze unless enabled?
        maximum = Integer(limit)
        raise ArgumentError, "outbox limit must be between 1 and 64" unless (1..64).cover?(maximum)

        each_record.select do |record|
          record.fetch("status") == "pending" ||
            record.fetch("status") == "acknowledged" ||
            (%w[retry_wait acknowledgement_retry_wait].include?(record.fetch("status")) &&
             Time.iso8601(record.fetch("retry_at")) <= now.utc)
        end.first(maximum).freeze
      end

      def park!(occurrence_id:, now: Time.now.utc)
        return nil unless enabled?
        id = text!(occurrence_id, "occurrence identity", max: 256)
        mutate(id) do |record|
          conflict!("acknowledged source handoff cannot be parked") if
            record["acknowledgement"]
          record["status"] = "blocked"
          record["retry_at"] = nil
          record["updated_at"] = timestamp(now)
          record
        end
      end

      def defer!(occurrence_id:, retry_at:, now: Time.now.utc)
        return nil unless enabled?
        id = text!(occurrence_id, "occurrence identity", max: 256)
        eligible_at = retry_at.utc
        conflict!("source handoff retry must be scheduled in the future") unless
          eligible_at > now.utc
        mutate(id) do |record|
          conflict!("settled source handoff cannot be deferred") if
            record.fetch("status") == "settled"
          record["status"] = record["acknowledgement"] ?
            "acknowledgement_retry_wait" : "retry_wait"
          record["retry_at"] = timestamp(eligible_at)
          record["updated_at"] = timestamp(now)
          record
        end
      end

      def resume!(occurrence_id:, now: Time.now.utc)
        return nil unless enabled?
        id = text!(occurrence_id, "occurrence identity", max: 256)
        mutate(id) do |record|
          conflict!("only a blocked source handoff may resume") unless
            record.fetch("status") == "blocked" && record["acknowledgement"].nil?
          record["status"] = "pending"
          record["retry_at"] = nil
          record["updated_at"] = timestamp(now)
          record
        end
      end

      def acknowledge!(occurrence_id:, admission_id:, task:, now: Time.now.utc)
        return nil unless enabled?
        id = text!(occurrence_id, "occurrence identity", max: 256)
        binding = normalize_task(task)
        admission = text!(admission_id, "admission identity", max: 256)
        receipt_id = "#{source}:#{Digest::SHA256.hexdigest([ id, admission, binding.fetch('slug'), binding.fetch('generation'), binding.fetch('evidence_digest'), @gate.epoch ].join(':'))}"
        mutate(id) do |record|
          acknowledgement = {
            "receipt_id" => receipt_id,
            "admission_id" => admission,
            "task" => binding,
            "source_epoch" => @gate.epoch,
            "acknowledged_at" => timestamp(now)
          }
          if record["acknowledgement"]
            exact = record.fetch("acknowledgement").except("acknowledged_at") ==
                    acknowledgement.except("acknowledged_at")
            conflict!("source acknowledgement conflicts") unless exact
            next record
          end
          conflict!("source epoch changed before acknowledgement") unless
            record.fetch("source_epoch") == @gate.epoch
          record["acknowledgement"] = acknowledgement
          record["status"] = "acknowledged"
          record["retry_at"] = nil
          record["updated_at"] = timestamp(now)
          record
        end
        receipt_id
      end

      def settle!(occurrence_id:, now: Time.now.utc)
        return nil unless enabled?
        id = text!(occurrence_id, "occurrence identity", max: 256)
        mutate(id) do |record|
          conflict!("source handoff settlement requires acknowledgement") unless
            %w[acknowledged acknowledgement_retry_wait settled].include?(record.fetch("status")) &&
              record["acknowledgement"]
          next record if record.fetch("status") == "settled"
          record["status"] = "settled"
          record["retry_at"] = nil
          record["updated_at"] = timestamp(now)
          record
        end
      end

      def acknowledged?(occurrence_id)
        %w[acknowledged acknowledgement_retry_wait settled].include?(
          fetch(occurrence_id)&.fetch("status")
        )
      end

      def published?(occurrence_id)
        !fetch(occurrence_id).nil?
      end

      private

      def mutate(id, create: false)
        relative = record_path(id)
        @directory.with_lock("#{relative}.lock") do
          original = @directory.read(relative, max_bytes: MAX_RECORD_BYTES, missing: true)
          record = original && parse_record(original, expected_id: id)
          conflict!("source outbox occurrence is missing") unless record || create
          replacement = yield(record && PatrolFix.deep_copy(record))
          validate_record!(replacement, expected_id: id)
          bytes = PatrolFix.canonical_json(replacement)
          corrupt!("source outbox record exceeds the size limit") if bytes.bytesize > MAX_RECORD_BYTES
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

      def each_record
        ids = []
        @directory.each_child("records", missing: true) do |name|
          next if name.end_with?(".lock")
          match = /\A([0-9a-f]{64})\.json\z/.match(name)
          corrupt!("source outbox inventory contains an unknown entry") unless match
          ids << name.delete_suffix(".json")
          corrupt!("source outbox inventory exceeds the bounded limit") if ids.length > MAX_RECORDS
        end
        ids.sort.map do |digest|
          bytes = @directory.read(File.join("records", "#{digest}.json"), max_bytes: MAX_RECORD_BYTES)
          parse_record(bytes)
        end
      rescue Hive::ManagedDirectory::UnsafeError => e
        corrupt!(e.message)
      end

      def parse_record(bytes, expected_id: nil)
        record = JSON.parse(bytes)
        corrupt!("source outbox record is not canonical") unless
          PatrolFix.canonical_json(record).b == bytes.b
        validate_record!(record, expected_id: expected_id)
      rescue JSON::ParserError, EncodingError
        corrupt!("source outbox record is malformed")
      end

      def validate_record!(record, expected_id: nil)
        keys = %w[
          acknowledgement created_at occurrence_id retry_at schema schema_version
          snapshot snapshot_digest source source_epoch status updated_at
        ]
        corrupt!("source outbox record fields are invalid") unless
          record.is_a?(Hash) && record.keys.sort == keys.sort
        corrupt!("source outbox schema is unsupported") unless
          record["schema"] == SCHEMA && record["schema_version"] == SCHEMA_VERSION
        corrupt!("source outbox source is invalid") unless record["source"] == source
        id = text!(record.fetch("occurrence_id"), "occurrence identity", max: 256)
        corrupt!("source outbox occurrence identity changed") if expected_id && id != expected_id
        snapshot = SourceSnapshot.new(record.fetch("snapshot"))
        corrupt!("source outbox snapshot belongs to a different engine") unless
          snapshot.to_h.fetch("engine") == source
        corrupt!("source outbox snapshot digest is invalid") unless
          record["snapshot_digest"].is_a?(String) && record["snapshot_digest"].match?(DIGEST) &&
          record["snapshot_digest"] == snapshot.digest
        text!(record.fetch("source_epoch"), "source epoch", max: 128)
        corrupt!("source outbox status is invalid") unless
          %w[pending blocked retry_wait acknowledged acknowledgement_retry_wait settled]
            .include?(record["status"])
        if %w[retry_wait acknowledgement_retry_wait].include?(record.fetch("status"))
          corrupt!("deferred source outbox lacks retry eligibility") unless record["retry_at"]
        elsif record["retry_at"]
          corrupt!("non-deferred source outbox has retry eligibility")
        end
        timestamp_value!(record["retry_at"], "retry_at") if record["retry_at"]
        validate_acknowledgement!(record["acknowledgement"]) if record["acknowledgement"]
        corrupt!("acknowledged source outbox lacks a receipt") if
          %w[acknowledged acknowledgement_retry_wait settled].include?(record["status"]) &&
            !record["acknowledgement"]
        corrupt!("non-acknowledged source outbox has a receipt") if
          !%w[acknowledged acknowledgement_retry_wait settled].include?(record["status"]) &&
            record["acknowledgement"]
        if record["acknowledgement"]
          acknowledgement = record.fetch("acknowledgement")
          corrupt!("source acknowledgement epoch conflicts with its handoff") unless
            acknowledgement.fetch("source_epoch") == record.fetch("source_epoch")
          binding = normalize_task(acknowledgement.fetch("task"))
          expected_receipt = "#{source}:#{Digest::SHA256.hexdigest([
            record.fetch('occurrence_id'), acknowledgement.fetch('admission_id'),
            binding.fetch('slug'), binding.fetch('generation'),
            binding.fetch('evidence_digest'), record.fetch('source_epoch')
          ].join(':'))}"
          corrupt!("source acknowledgement receipt is inconsistent") unless
            acknowledgement.fetch("receipt_id") == expected_receipt
        end
        timestamp_value!(record.fetch("created_at"), "created_at")
        timestamp_value!(record.fetch("updated_at"), "updated_at")
        PatrolFix.deep_freeze(record)
      rescue SourceSnapshot::InvalidSnapshot => e
        corrupt!(e.message)
      end

      def validate_acknowledgement!(value)
        keys = %w[acknowledged_at admission_id receipt_id source_epoch task]
        corrupt!("source acknowledgement fields are invalid") unless
          value.is_a?(Hash) && value.keys.sort == keys.sort
        text!(value.fetch("receipt_id"), "source receipt identity", max: 256)
        text!(value.fetch("admission_id"), "admission identity", max: 256)
        text!(value.fetch("source_epoch"), "source epoch", max: 128)
        normalize_task(value.fetch("task"))
        timestamp_value!(value.fetch("acknowledged_at"), "acknowledged_at")
      end

      def normalize_task(task)
        conflict!("source task binding fields are invalid") unless
          task.is_a?(Hash) && task.keys.sort == %w[evidence_digest generation slug]
        slug = text!(task.fetch("slug"), "task slug", max: 64)
        conflict!("source task slug is invalid") unless slug.match?(SLUG)
        generation = task.fetch("generation")
        conflict!("source task generation is invalid") unless generation.is_a?(Integer) && generation.positive?
        digest = task.fetch("evidence_digest")
        conflict!("source task evidence digest is invalid") unless digest.is_a?(String) && digest.match?(DIGEST)
        { "slug" => slug, "generation" => generation, "evidence_digest" => digest }
      rescue KeyError
        conflict!("source task binding fields are invalid")
      end

      def record_path(id)
        File.join("records", "#{Digest::SHA256.hexdigest(id)}.json")
      end

      def text!(value, label, max:)
        conflict!("#{label} is invalid") unless value.is_a?(String) && !value.empty? &&
          value.bytesize <= max && !value.match?(/[\u0000-\u001f\u007f]/)
        value
      end

      def timestamp(value) = value.utc.iso8601

      def timestamp_value!(value, label)
        parsed = Time.iso8601(value.to_s)
        corrupt!("#{label} is invalid") unless parsed.utc? && value.end_with?("Z")
      rescue ArgumentError
        corrupt!("#{label} is invalid")
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
