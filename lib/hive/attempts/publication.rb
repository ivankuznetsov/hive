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
        id = publication_attempt_id(attempt_id)
        names = Array(consumers).map { |value| consumer_name(value) }.uniq.sort
        if names.empty? || names.length > MAX_CONSUMERS
          raise RepositoryError, "pending finalization consumers are invalid"
        end
        database.transaction do |db|
          row = db[:terminal_pending_publications].where(attempt_id: id).first
          raise RepositoryError, "final attempt is not pending publication" unless row
          current = row[:publication_json] && decode(row[:publication_json])
          if current && current.fetch("consumers").keys.sort != names
            raise RepositoryError, "pending finalization conflicts with existing obligations"
          end
          current ||= {
            "attempt_id" => id,
            "consumers" => names.to_h { |name| [ name, false ] }
          }
          db[:terminal_pending_publications].where(attempt_id: id).update(
            publication_json: encode(current)
          )
          current.freeze
        end
      end

      def publication(attempt_id)
        id = publication_attempt_id(attempt_id)
        row = database.read do |db|
          db[:terminal_pending_publications].where(attempt_id: id).first
        end
        return nil unless row&.fetch(:publication_json)
        parse(row.fetch(:publication_json), id)
      end

      def acknowledge_publication(attempt_id, consumer:)
        id = publication_attempt_id(attempt_id)
        name = consumer_name(consumer)
        database.transaction do |db|
          row = db[:terminal_pending_publications].where(attempt_id: id).first
          current = row && row[:publication_json] && parse(row[:publication_json], id)
          raise RepositoryError, "pending finalization is missing" unless current
          unless current.fetch("consumers").key?(name)
            raise RepositoryError, "pending finalization consumer is unknown"
          end
          replacement = current.merge(
            "consumers" => current.fetch("consumers").merge(name => true)
          )
          complete = replacement.fetch("consumers").values.all?(true)
          db[:terminal_pending_publications].where(attempt_id: id).update(
            publication_json: encode(replacement),
            state: complete ? "published" : "pending",
            published_at: complete ? Record.iso8601(Time.now.utc) : nil
          )
          replacement.freeze
        end
      end

      def publication_complete?(attempt_id)
        entry = publication(attempt_id)
        entry && entry.fetch("consumers").values.all?(true) || false
      end

      def finish_publication(attempt_id)
        id = publication_attempt_id(attempt_id)
        database.transaction do |db|
          row = db[:terminal_pending_publications].where(attempt_id: id).first
          return false unless row&.fetch(:publication_json)
          entry = parse(row.fetch(:publication_json), id)
          unless entry.fetch("consumers").values.all?(true)
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

      def parse(bytes, expected_id)
        data = decode(bytes)
        consumers = data["consumers"] if data.is_a?(Hash)
        valid = data.is_a?(Hash) && data.keys.sort == %w[attempt_id consumers] &&
          data["attempt_id"] == expected_id && consumers.is_a?(Hash) &&
          !consumers.empty? && consumers.length <= MAX_CONSUMERS &&
          consumers.keys.all? { |name| consumer_name(name) == name } &&
          consumers.values.all? { |value| value == true || value == false }
        raise RepositoryError, "pending finalization row is invalid" unless valid
        data
      rescue RuntimeControlPlane::Error, TypeError, ArgumentError
        raise RepositoryError, "pending finalization row is invalid"
      end

      def consumer_name(value)
        name = value.to_s
        return name if /\A[a-z][a-z0-9_-]{0,63}\z/.match?(name)
        raise RepositoryError, "pending finalization consumer is invalid"
      end

      def publication_attempt_id(value)
        id = value.to_s
        return id if /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(id)
        raise RepositoryError, "pending finalization attempt id is invalid"
      end

      def encode(value) = RuntimeControlPlane::Codec.dump_json(value)
      def decode(value) = RuntimeControlPlane::Codec.load_json(value)
    end
  end
end
