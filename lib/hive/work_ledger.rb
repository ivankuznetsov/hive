require "hive/errors"
require "json"

module Hive
  # Policy-light mechanics for ordered descriptors and append-only JSONL
  # ledgers. Callers own every record schema and all domain policy: WorkLedger
  # only validates descriptor topology, makes appends durable, and replays
  # records through caller-supplied validation.
  #
  # In particular, this facade does not define a public Hive journal,
  # projection, workflow, task-path, or migration format. Hive remains its
  # first consumer and owns those compatibility contracts in its adapters.
  module WorkLedger
    class Error < Hive::Error; end
    class InvalidRequest < Error; end
    class InvalidDescriptor < InvalidRequest; end
    class InvalidRecord < Error; end
    class Conflict < Error; end
    class AppendFailed < Error; end
    class ReplayFailed < Error; end

    module Values
      module_function

      def immutable_string(value)
        value.to_s.dup.freeze
      end

      def immutable_optional_string(value)
        value && immutable_string(value)
      end

      def immutable_json(value)
        JSON.parse(JSON.generate(value), freeze: true)
      end

      def immutable_strings(values)
        values.map { |value| immutable_string(value) }.freeze
      end
    end
    private_constant :Values

    AppendReceipt = Data.define(:cursor, :record_id, :ledger_hash, :records) do
      def initialize(cursor:, record_id:, ledger_hash:, records:)
        super(
          cursor: Integer(cursor),
          record_id: Values.immutable_string(record_id),
          ledger_hash: Values.immutable_string(ledger_hash),
          records: Values.immutable_json(records)
        )
      end
    end

    ReplayReceipt = Data.define(:cursor, :record_id, :ledger_hash, :records) do
      def initialize(cursor:, record_id:, ledger_hash:, records:)
        super(
          cursor: Integer(cursor),
          record_id: Values.immutable_optional_string(record_id),
          ledger_hash: Values.immutable_string(ledger_hash),
          records: Values.immutable_json(records)
        )
      end
    end

    DescriptorReceipt = Data.define(:identity, :stage_names, :stage_dirs) do
      def initialize(identity:, stage_names:, stage_dirs:)
        super(
          identity: Values.immutable_string(identity),
          stage_names: Values.immutable_strings(stage_names),
          stage_dirs: Values.immutable_strings(stage_dirs)
        )
      end
    end

    # Public append capability returned by `.journal`. Construction and path
    # normalization stay behind the facade while callers retain a small,
    # explicit append/idempotency vocabulary.
    class JournalHandle
      def initialize(journal)
        @journal = journal
        freeze
      end

      def append(records)
        @journal.append(records)
      end

      def append_idempotent(record, idempotency_key:, key_for:, signature_for:)
        @journal.append_idempotent(
          record,
          idempotency_key: idempotency_key,
          key_for: key_for,
          signature_for: signature_for
        )
      end
    end
  end
end

require "hive/work_ledger/descriptor_validator"
require "hive/work_ledger/journal"
require "hive/work_ledger/replay"

module Hive
  module WorkLedger
    module_function

    def validate_descriptor(identity:, stages:, allowed_kinds:)
      DescriptorValidator.validate(
        identity: identity,
        stages: stages,
        allowed_kinds: allowed_kinds
      )
    end

    def journal(path:, lock_path:, record_id:)
      JournalHandle.new(
        Journal.new(path: path, lock_path: lock_path, record_id: record_id)
      )
    end

    def replay(bytes:, record_id:, source_label: "ledger", record_label: "record_id", &validator)
      Replay.call(
        bytes: bytes,
        record_id: record_id,
        source_label: source_label,
        record_label: record_label,
        validator: validator
      )
    end
  end
end
