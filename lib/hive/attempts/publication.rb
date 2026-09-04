require "hive/runtime_control_plane"
require "hive/runtime_control_plane/payload_store"
require "time"

module Hive
  module Attempts
    module Publication
      PUBLICATION_COLUMNS = {
        "journal" => :publication_journal_acknowledged,
        "accounting" => :publication_accounting_acknowledged,
        "dispatch" => :publication_dispatch_acknowledged
      }.freeze

      def seal_terminal_payloads(record)
        unless record.is_a?(Record) && record.final?
          raise RepositoryError, "only final attempt payloads can be sealed"
        end

        specs = terminal_payload_specs(record)
        payload_store.with_reference_custody(specs.map { |spec| spec.fetch(:source) }) do
          prepared = specs.map do |spec|
            spec.merge(reference: prepare_sealed_reference(spec.fetch(:source)))
          end
          database.transaction do |db|
            prepared.each { |spec| persist_sealed_reference(db, record, spec) }
          end
          remove_open_sources(prepared)
          prepared.to_h do |spec|
            [ spec.fetch(:payload_id), output_reference(spec.fetch(:reference)) ]
          end.freeze
        end
      rescue InvalidOutputReference, RuntimeControlPlane::Error,
             Sequel::Error, SystemCallError, IOError => error
        raise RepositoryError, "attempt payload sealing failed: #{error.message}"
      end

      def sealed_payload_reference(reference)
        source = normalized_output_reference(reference)
        row = database.read do |db|
          sealed_payloads(db).where(
            sha256: source.fetch("sha256"), bytes: source.fetch("size")
          ).first
        end
        return nil unless row

        canonical = payload_reference(row)
        payload_store.read_sealed(canonical)
        output_reference(canonical)
      rescue InvalidOutputReference, RuntimeControlPlane::Error,
             Sequel::Error => error
        raise RepositoryError, "sealed attempt payload is unreadable: #{error.message}"
      end

      def prepare_publication(attempt_id:)
        id = safe_id(attempt_id, error: "pending finalization attempt id is invalid")
        entry = database.read { |db| publication_in(db, id) }
        raise RepositoryError, "final attempt is not pending publication" unless entry

        entry
      end

      def publication(attempt_id)
        id = safe_id(attempt_id, error: "pending finalization attempt id is invalid")
        database.read { |db| publication_in(db, id) }
      end

      def acknowledge_publication(attempt_id, consumer:)
        id = safe_id(attempt_id, error: "pending finalization attempt id is invalid")
        name = consumer_name(consumer)
        column = PUBLICATION_COLUMNS.fetch(name)
        database.transaction do |db|
          row = db[:attempts].where(attempt_id: id).first
          unless row && row[:terminal_receipt_json]
            raise RepositoryError, "final attempt is not pending publication"
          end
          db[:attempts].where(attempt_id: id, column => 0).update(column => 1)

          publication_in(db, id)
        end
      end

      def publication_complete?(attempt_id)
        entry = publication(attempt_id)
        !!entry && entry.fetch("consumers").values.all?
      end

      def finish_publication(attempt_id)
        entry = publication(attempt_id)
        return false unless entry
        raise RepositoryError, "pending finalization is incomplete" unless
          entry.fetch("consumers").values.all?

        true
      end

      private

      def terminal_payload_specs(record)
        receipt = record.receipt
        outputs = receipt&.fetch("output_references", nil) || record["current_outputs"]
        log = receipt&.fetch("log_reference", nil) || record["log_reference"]
        specs = Array(outputs).each_with_index.map do |reference, index|
          {
            payload_id: "attempt-output:#{record.attempt_id}:#{index}",
            kind: "attempt_output", source: normalized_output_reference(reference)
          }
        end
        if log
          specs.unshift(
            payload_id: "attempt-log:#{record.attempt_id}",
            kind: "attempt_log", source: normalized_output_reference(log)
          )
        end
        specs
      end

      def normalized_output_reference(reference)
        value = Hive::StringifyKeys.call(reference)
        OutputReference.validate_shape!(value)
        value
      end

      def prepare_sealed_reference(source)
        existing = database.read do |db|
          sealed_payloads(db).where(
            sha256: source.fetch("sha256"), bytes: source.fetch("size")
          ).first
        end
        if existing
          reference = payload_reference(existing)
          payload_store.read_sealed(reference)
          return reference
        end

        source_path = File.join(root, source.fetch("path"))
        payload_store.seal(
          source_path,
          expected_sha256: source.fetch("sha256"),
          expected_size: source.fetch("size")
        )
      end

      def persist_sealed_reference(db, record, spec)
        reference = spec.fetch(:reference)
        row = {
          payload_id: spec.fetch(:payload_id), attempt_id: record.attempt_id,
          kind: spec.fetch(:kind), relative_path: reference.fetch("path"),
          sha256: reference.fetch("sha256"), bytes: reference.fetch("size"),
          state: "sealed", created_at: Record.iso8601(Time.now.utc)
        }
        existing = db[:payload_references].where(payload_id: row.fetch(:payload_id)).first
        if existing
          identity = row.slice(:attempt_id, :kind, :relative_path, :sha256, :bytes)
          unless identity.all? { |key, value| existing.fetch(key) == value } &&
                 %w[sealed releasable].include?(existing.fetch(:state))
            raise RepositoryError, "sealed attempt payload identity conflicts"
          end
          return
        end
        db[:payload_references].insert(row)
      end

      def remove_open_sources(prepared)
        open_prefix = "open#{File::SEPARATOR}"
        prepared.map { |spec| spec.fetch(:source).fetch("path") }.uniq.each do |relative|
          next unless relative.start_with?(open_prefix)

          path = File.join(root, relative)
          status = File.lstat(path)
          raise RepositoryError, "open attempt payload is unsafe" unless status.file? && !status.symlink?

          File.unlink(path)
        rescue Errno::ENOENT
          nil
        end
      end

      def sealed_payloads(db)
        db[:payload_references].where(state: %w[sealed releasable])
      end

      def payload_reference(row)
        {
          "algorithm" => "sha256", "sha256" => row.fetch(:sha256),
          "size" => row.fetch(:bytes), "path" => row.fetch(:relative_path)
        }.freeze
      end

      def output_reference(reference)
        reference.slice("path", "size", "sha256").freeze
      end

      def publication_in(db, attempt_id)
        row = db[:attempts].where(attempt_id: attempt_id).first
        return nil unless row && row[:terminal_receipt_json]

        consumers = PUBLICATION_COLUMNS.to_h do |name, column|
          [ name, row.fetch(column) == 1 ]
        end

        {
          "attempt_id" => attempt_id,
          "receipt_digest" => row.fetch(:terminal_receipt_digest),
          "task_source_fingerprint" => row.fetch(:terminal_task_source_fingerprint),
          "created_at" => row.fetch(:terminal_publication_created_at),
          "consumers" => consumers.freeze
        }.freeze
      end

      def consumer_name(value)
        name = value.to_s
        return name if PUBLICATION_COLUMNS.key?(name)
        raise RepositoryError, "pending finalization consumer is invalid"
      end
    end
  end
end
