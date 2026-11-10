require "digest"
require "json"
require "hive/attempts/contracts"
require "hive/attempts/record"
require "hive/output_reference"
require "hive/runtime_control_plane/payload_store"

module Hive
  module Attempts
    # A bounded pending operation, never an independent source of success.
    # Only the reconciler's identity/custody decision permits replay; receipt
    # validation and the ordinary lease CAS remain the terminal authority.
    class PendingBookkeeping
      FILENAME = "pending-bookkeeping.json".freeze
      SCHEMA = "hive-attempt-pending-bookkeeping".freeze
      MAX_BYTES = 1024 * 1024
      MAX_REFERENCES = 64
      MAX_FIELD_BYTES = 1024
      REASONS = %w[runtime_bookkeeping_busy first_heartbeat_owner_unverifiable_ceiling].freeze
      BINDING_FIELDS = %w[attempt_id request_id task_id project task_slug intended_stage task_generation
                          task_input_epoch ownership_generation lease_version wrapper worker].freeze
      KEYS = %w[schema schema_version installation_id binding operation reason observed_at terminal_receipt
                receipt_sha256 receipt_size].freeze
      ReadResult = Data.define(:status, :document, :diagnostic)
      class InvalidEvidence < RepositoryError; end
      class StorageError < RepositoryError; end

      def initialize(store:, clock: -> { Time.now.utc }, filesystem: File)
        @store, @clock, @filesystem = store, clock, filesystem
      end

      def prepare_completion(record, receipt:, operation: "terminalize")
        validate_receipt!(record, receipt)
        references(receipt).each { |reference| verify_reference!(reference) }
        write(record, operation: operation, receipt: receipt, reason: "runtime_bookkeeping_busy")
      end

      def record_busy(record, operation:, reason: "runtime_bookkeeping_busy")
        # A previously prepared completion always wins over later exhaustion.
        @store.payload_store.with_attempt_custody(record.attempt_id) do
          current = read(record)
          return path(record) if current.status == :valid && current.document["terminal_receipt"]
          # Preserve invalid/stale evidence for diagnosis rather than silently
          # replacing it with a document that appears trustworthy.
          return path(record) if current.status == :invalid
          write(record, operation: operation, receipt: nil, reason: reason)
        end
      end

      def read(record)
        bytes = @store.payload_store.read_open(
          attempt_id: record.attempt_id, name: FILENAME, max_bytes: MAX_BYTES
        )
        return ReadResult.new(status: :absent, document: nil, diagnostic: nil) unless bytes
        document = JSON.parse(bytes)
        validate_document!(record, document)
        ReadResult.new(status: :valid, document: document, diagnostic: nil)
      rescue InvalidEvidence, InvalidReceipt, Hive::InvalidOutputReference,
             RuntimeControlPlane::Error, JSON::ParserError, SystemCallError, IOError => error
        ReadResult.new(status: :invalid, document: nil, diagnostic: error.message.to_s.byteslice(0, 512))
      end

      # Caller has resolved wrapper and worker custody. Do not repeat those
      # checks here: the claimed-launch bounded custody exception also enters
      # through this seam. The current row and exact lease are still CAS-bound.
      def replay(record, document, authority: nil, timeout_sec: nil)
        validate_document!(record, document)
        receipt = document.fetch("terminal_receipt")
        return nil unless receipt
        references(receipt).each { |reference| verify_reference!(reference) }
        @store.commit_prepared_terminal(
          record, receipt, authority: authority, timeout_sec: timeout_sec,
          allow_claimed_launch: true
        )
      end

      def present?(record)
        @filesystem.lstat(path(record))
        true
      rescue Errno::ENOENT
        false
      end

      # Receipt/publication or completed loss recovery must already be durable.
      # Invalid bytes are retained as bounded diagnostic evidence until this
      # same durable disposition; they never authorize their own retirement.
      def retire(record)
        return false unless record.final?
        return false unless @store.publication_complete?(record.attempt_id) || recovery_disposed?(record)
        @store.payload_store.remove_open(attempt_id: record.attempt_id, name: FILENAME)
      end

      private

      def write(record, operation:, receipt:, reason:)
        raise InvalidEvidence, "pending bookkeeping requires an admitted live attempt" if record.final?
        raise InvalidEvidence, "pending bookkeeping reason is unsupported" unless REASONS.include?(reason)
        field!(operation)
        receipt_bytes = receipt && JSON.generate(receipt)
        document = {
          "schema" => SCHEMA, "schema_version" => 1,
          "installation_id" => @store.installation_id,
          "binding" => binding(record), "operation" => operation, "reason" => reason,
          "observed_at" => Record.iso8601(@clock.call), "terminal_receipt" => receipt,
          "receipt_sha256" => receipt_bytes && Digest::SHA256.hexdigest(receipt_bytes),
          "receipt_size" => receipt_bytes&.bytesize
        }
        validate_document!(record, document)
        bytes = JSON.generate(document) + "\n"
        raise InvalidEvidence, "pending bookkeeping document exceeds its size limit" if bytes.bytesize > MAX_BYTES
        @store.payload_store.write_open(
          attempt_id: record.attempt_id, name: FILENAME, bytes: bytes, require_existing: true
        )
      rescue RuntimeControlPlane::Error, SystemCallError, IOError => error
        raise StorageError, "pending bookkeeping storage failed: #{error.message}"
      end

      def validate_document!(record, document)
        unless document.is_a?(Hash) && document.keys.sort == KEYS.sort
          raise InvalidEvidence, "pending bookkeeping document shape is invalid"
        end
        unless document["schema"] == SCHEMA && document["schema_version"] == 1
          raise InvalidEvidence, "pending bookkeeping schema is unsupported"
        end
        field!(document["installation_id"])
        unless document["installation_id"] == @store.installation_id && document["binding"] == binding(record)
          raise InvalidEvidence, "pending bookkeeping identity binding differs from the current attempt"
        end
        field!(document["operation"])
        raise InvalidEvidence, "pending bookkeeping reason is unsupported" unless REASONS.include?(document["reason"])
        Record.parse_time(document["observed_at"], label: "pending observation", error_class: InvalidEvidence)
        receipt = document["terminal_receipt"]
        unless receipt
          unless document["receipt_sha256"].nil? && document["receipt_size"].nil?
            raise InvalidEvidence, "pending bookkeeping nonterminal receipt is invalid"
          end
          return true
        end
        validate_receipt!(record, receipt)
        encoded = JSON.generate(receipt)
        unless document["receipt_size"] == encoded.bytesize &&
               document["receipt_sha256"] == Digest::SHA256.hexdigest(encoded)
          raise InvalidEvidence, "pending bookkeeping receipt hash or size differs"
        end
        true
      end

      def binding(record)
        BINDING_FIELDS.to_h do |field|
          value = record[field]
          field!(value) if value.is_a?(String)
          [ field, value ]
        end
      end

      def field!(value)
        unless value.is_a?(String) && !value.empty? && value.bytesize <= MAX_FIELD_BYTES
          raise InvalidEvidence, "pending bookkeeping field is invalid or too long"
        end
      end

      def validate_receipt!(record, receipt)
        Record.validate_receipt!(
          receipt, attempt_id: record.attempt_id, task_generation: record.task_generation,
          task_input_epoch: record.task_input_epoch, ownership_generation: record.ownership_generation,
          terminal_lease_version: record.lease_version + 1, routing: record["routing"]
        )
        raise InvalidEvidence, "pending bookkeeping has too many references" if references(receipt).size > MAX_REFERENCES
      end

      def references(receipt)
        receipt.fetch("output_references") + [ receipt.fetch("log_reference") ]
      end

      # Streaming bounds memory and checks the opened inode against lstat both
      # before and after hashing; parent redirection, links and replacement are
      # rejected. Open logs are immutable once completion has been prepared.
      def verify_reference!(reference)
        OutputReference.validate_shape!(reference)
        relative = reference.fetch("path")
        field!(relative)
        candidate = File.join(@filesystem.realpath(@store.root), relative)
        parent = File.dirname(candidate)
        unless @filesystem.realpath(parent) == parent
          raise InvalidEvidence, "pending bookkeeping reference parent is redirected"
        end
        before = @filesystem.lstat(candidate)
        unless before.file? && !before.symlink? && before.nlink == 1 && before.uid == Process.euid &&
               before.size == reference.fetch("size") && before.size <= RuntimeControlPlane::PayloadStore::MAX_PAYLOAD_BYTES
          raise InvalidEvidence, "pending bookkeeping reference size or custody is invalid"
        end
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        digest = Digest::SHA256.new
        @filesystem.open(candidate, flags) do |file|
          raise InvalidEvidence, "pending bookkeeping reference identity changed" unless same_snapshot?(before, file.stat)
          size = 0
          while (chunk = file.read(64 * 1024))
            size += chunk.bytesize
            raise InvalidEvidence, "pending bookkeeping reference grew" if size > before.size
            digest.update(chunk)
          end
          unless size == before.size && same_snapshot?(before, file.stat) && same_snapshot?(before, @filesystem.lstat(candidate))
            raise InvalidEvidence, "pending bookkeeping reference changed"
          end
        end
        unless digest.hexdigest == reference.fetch("sha256")
          raise InvalidEvidence, "pending bookkeeping reference digest differs"
        end
        true
      end

      def same_snapshot?(left, right)
        [ left.dev, left.ino, left.size, left.mtime, left.ctime ] ==
          [ right.dev, right.ino, right.size, right.mtime, right.ctime ]
      end

      def recovery_disposed?(record)
        return false unless record.state == "lost"
        require "hive/attempts/lost_outcome"
        outcome = LostOutcomeTransition.new(store: @store).fetch(record.attempt_id)
        LostOutcomeTransition::FINAL_PHASES.include?(outcome&.fetch("phase", nil)) &&
          LostOutcomeTransition::SAFE_CLEANUPS.include?(outcome["cleanup"])
      end

      def path(record)
        @store.output_path(record.attempt_id, FILENAME)
      end
    end
  end
end
