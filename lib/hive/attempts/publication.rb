require "hive/runtime_control_plane"
require "hive/runtime_control_plane/payload_store"

module Hive
  module Attempts
    module Publication
      MAX_CONSUMERS = 32

      def seal_terminal_payloads(record)
        unless record.is_a?(Record) && record.final?
          raise RepositoryError, "only final attempt payloads can be sealed"
        end

        prepared = terminal_payload_specs(record).map do |spec|
          spec.merge(reference: prepare_sealed_reference(spec.fetch(:source)))
        end
        database.transaction do |db|
          prepared.each { |spec| persist_sealed_reference(db, record, spec) }
        end
        remove_open_sources(prepared)
        prepared.to_h do |spec|
          [ spec.fetch(:payload_id), output_reference(spec.fetch(:reference)) ]
        end.freeze
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

      def prepare_publication(attempt_id:, consumers:)
        id = safe_id(attempt_id, error: "pending finalization attempt id is invalid")
        names = Array(consumers).map { |value| consumer_name(value) }.uniq.sort
        if names.empty? || names.length > MAX_CONSUMERS
          raise RepositoryError, "pending finalization consumers are invalid"
        end
        database.transaction do |db|
          pending = db[:terminal_pending_publications].where(attempt_id: id)
          raise RepositoryError, "final attempt is not pending publication" unless pending.any?
          obligations = db[:terminal_publication_obligations].where(attempt_id: id)
          existing = obligations.order(:consumer).select_map(:consumer)
          if existing.any? && existing != names
            raise RepositoryError, "pending finalization conflicts with existing obligations"
          end
          names.each do |name|
            obligations.insert_conflict.insert(
              attempt_id: id, consumer: name, acknowledged: 0
            )
          end
          publication_in(db, id)
        end
      end

      def publication(attempt_id)
        id = safe_id(attempt_id, error: "pending finalization attempt id is invalid")
        database.read { |db| publication_in(db, id) }
      end

      def acknowledge_publication(attempt_id, consumer:)
        id = safe_id(attempt_id, error: "pending finalization attempt id is invalid")
        name = consumer_name(consumer)
        database.transaction do |db|
          changed = db[:terminal_publication_obligations].where(
            attempt_id: id, consumer: name
          ).update(acknowledged: 1)
          raise RepositoryError, "pending finalization consumer is unknown" unless changed == 1

          publication_in(db, id)
        end
      end

      def publication_complete?(attempt_id)
        entry = publication(attempt_id)
        !!entry && entry.fetch("consumers").values.all?
      end

      def finish_publication(attempt_id)
        id = safe_id(attempt_id, error: "pending finalization attempt id is invalid")
        database.transaction do |db|
          obligations = db[:terminal_publication_obligations].where(attempt_id: id)
          return false unless obligations.any?
          if obligations.where(acknowledged: 0).any?
            raise RepositoryError, "pending finalization is incomplete"
          end
          db[:terminal_pending_publications].where(attempt_id: id).delete == 1
        end
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
                 %w[sealed pinned].include?(existing.fetch(:state))
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
        db[:payload_references].where(state: %w[sealed pinned])
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
        consumers = db[:terminal_publication_obligations].where(attempt_id: attempt_id)
          .order(:consumer).to_h { |row| [ row.fetch(:consumer), row.fetch(:acknowledged) == 1 ] }
        return nil if consumers.empty?

        {
          "attempt_id" => attempt_id,
          "consumers" => consumers.freeze
        }.freeze
      end

      def consumer_name(value)
        name = value.to_s
        return name if /\A[a-z][a-z0-9_-]{0,63}\z/.match?(name)
        raise RepositoryError, "pending finalization consumer is invalid"
      end
    end
  end
end
