require "hive/errors"

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

    AppendReceipt = Data.define(:cursor, :record_id, :ledger_hash, :records)
    ReplayReceipt = Data.define(:cursor, :record_id, :ledger_hash, :records)
    DescriptorReceipt = Data.define(:identity, :stage_names, :stage_dirs)

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
