require "date"
require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/digest/errors"

module Hive
  module Digest
    # Durable, owner-private progress for one calendar day's Telegram digest.
    # The payload and its exact chunks are persisted before the first send;
    # next_chunk is atomically advanced after each accepted Telegram response.
    class DeliveryCheckpointStore
      SCHEMA = "hive-digest-delivery".freeze
      SCHEMA_VERSION = 1

      def initialize(root:, clock: -> { Time.now })
        @root = root
        @clock = clock
      end

      def synchronize(digest_date)
        key = normalize_date(digest_date)
        lock = begin
          ensure_root!
          file = File.open(lock_path(key), File::RDWR | File::CREAT, 0o600)
          file.flock(File::LOCK_EX)
          file
        rescue SystemCallError => e
          raise DeliveryCheckpointError,
                "hive digest: cannot lock delivery checkpoint for #{digest_date}: #{e.message}"
        end

        yield key
      ensure
        lock&.flock(File::LOCK_UN)
        lock&.close
      end

      def load(key)
        path = checkpoint_path(key)
        return nil unless File.exist?(path)

        validate!(JSON.parse(File.read(path)), expected_date: key)
      rescue DeliveryCheckpointError, PermanentDeliveryCheckpointError
        raise
      rescue JSON::ParserError => e
        raise PermanentDeliveryCheckpointError,
              "hive digest: corrupt delivery checkpoint for #{key}: #{e.class}: #{e.message}"
      rescue SystemCallError => e
        raise DeliveryCheckpointError,
              "hive digest: unreadable delivery checkpoint for #{key}: #{e.class}: #{e.message}"
      end

      def create(key:, chat_id:, payload:, chunks:)
        now = timestamp
        write(
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "digest_date" => key,
          "chat_id" => chat_id,
          "payload" => payload,
          "payload_sha256" => ::Digest::SHA256.hexdigest(payload),
          "chunks" => chunks,
          "chunks_sha256" => checksum(chunks),
          "next_chunk" => 0,
          "total_chunks" => chunks.size,
          "created_at" => now,
          "updated_at" => now
        )
      end

      def begin_attempt(checkpoint, chunk_index:, payload:, parse_mode:)
        unless checkpoint["in_flight"].nil?
          raise PermanentDeliveryCheckpointError,
                "hive digest: checkpoint already has an in-flight chunk"
        end

        write(
          checkpoint.merge(
            "in_flight" => delivery_unit(
              chunk_index: chunk_index, payload: payload, parse_mode: parse_mode
            ),
            "updated_at" => timestamp
          )
        )
      end

      # Telegram has definitively rejected the MarkdownV2 request. Replace its
      # in-flight marker with the stable HTML representation in one atomic
      # write, so a later safe retry never repeats the deterministic 400.
      def prepare_fallback(checkpoint, chunk_index:, payload:)
        updated = checkpoint.reject { |key, _value| key == "in_flight" }.merge(
          "pending_variant" => delivery_unit(
            chunk_index: chunk_index, payload: payload, parse_mode: "html"
          ),
          "updated_at" => timestamp
        )
        write(updated)
      end

      # A structured Telegram error response proves that no message was
      # accepted. Clear only the attempt marker; a pending HTML variant remains
      # the canonical representation for the next safe retry.
      def reject_attempt(checkpoint)
        write(
          checkpoint.reject { |key, _value| key == "in_flight" }.merge(
            "updated_at" => timestamp
          )
        )
      end

      def accept(checkpoint, next_chunk:)
        updated = checkpoint.reject do |key, _value|
          %w[in_flight pending_variant].include?(key)
        end.merge(
          "next_chunk" => next_chunk,
          "updated_at" => timestamp
        )
        updated["completed_at"] = timestamp if next_chunk == updated.fetch("total_chunks")
        write(updated)
      end

      def mark_permanent(checkpoint, error:, outcome_known: false)
        base = if outcome_known
          checkpoint.reject { |key, _value| key == "in_flight" }
        else
          checkpoint
        end
        write(
          base.merge(
            "permanent_failure" => {
              "error_class" => error.class.name,
              "message" => error.message,
              "recorded_at" => timestamp
            },
            "updated_at" => timestamp
          )
        )
      end

      private

      def write(data)
        validated = validate!(data, expected_date: data.fetch("digest_date"))
        path = checkpoint_path(validated.fetch("digest_date"))
        Hive::AtomicFile.write(
          path,
          "#{JSON.pretty_generate(validated)}\n",
          mode: 0o600,
          fsync: true
        )
        Hive::AtomicFile.fsync_directory(File.dirname(path))
        validated
      rescue DeliveryCheckpointError, PermanentDeliveryCheckpointError
        raise
      rescue KeyError, JSON::GeneratorError => e
        raise PermanentDeliveryCheckpointError,
              "hive digest: cannot persist valid delivery checkpoint: #{e.class}: #{e.message}"
      rescue SystemCallError => e
        raise DeliveryCheckpointError,
              "hive digest: cannot persist delivery checkpoint: #{e.class}: #{e.message}"
      end

      def validate!(data, expected_date:)
        unless data.is_a?(Hash) &&
               data["schema"] == SCHEMA &&
               data["schema_version"] == SCHEMA_VERSION &&
               data["digest_date"] == expected_date
          raise PermanentDeliveryCheckpointError,
                "hive digest: invalid delivery checkpoint identity for #{expected_date}"
        end

        payload = data["payload"]
        chunks = data["chunks"]
        next_chunk = data["next_chunk"]
        total_chunks = data["total_chunks"]
        valid_progress = next_chunk.is_a?(Integer) &&
                         total_chunks.is_a?(Integer) &&
                         next_chunk.between?(0, total_chunks)
        unless payload.is_a?(String) &&
               data["payload_sha256"] == ::Digest::SHA256.hexdigest(payload) &&
               chunks.is_a?(Array) &&
               chunks.all? { |chunk| chunk.is_a?(String) && !chunk.empty? } &&
               data["chunks_sha256"] == checksum(chunks) &&
               total_chunks == chunks.size &&
               total_chunks.positive? &&
               valid_progress
          raise PermanentDeliveryCheckpointError,
                "hive digest: corrupt delivery checkpoint for #{expected_date}"
        end

        validate_delivery_state!(
          data,
          chunks: chunks,
          next_chunk: next_chunk,
          total_chunks: total_chunks,
          expected_date: expected_date
        )

        permanent_failure = data["permanent_failure"]
        if permanent_failure &&
           (!permanent_failure.is_a?(Hash) ||
            permanent_failure["error_class"].to_s.empty? ||
            permanent_failure["message"].to_s.empty?)
          raise PermanentDeliveryCheckpointError,
                "hive digest: corrupt permanent failure in checkpoint for #{expected_date}"
        end

        data
      end

      def validate_delivery_state!(data, chunks:, next_chunk:, total_chunks:, expected_date:)
        variant = data["pending_variant"]
        attempt = data["in_flight"]
        if next_chunk == total_chunks && (variant || attempt)
          invalid_delivery_state!(expected_date)
        end

        validate_unit!(variant, next_chunk, expected_date) if variant
        validate_unit!(attempt, next_chunk, expected_date) if attempt
        if variant && (
          variant["parse_mode"] != "html" ||
          (attempt && !same_unit?(variant, attempt))
        )
          invalid_delivery_state!(expected_date)
        end

        expected_payload = variant ? variant.fetch("payload") : chunks[next_chunk]
        expected_mode = variant ? "html" : "markdown_v2"
        if attempt && (
          attempt["payload"] != expected_payload ||
          attempt["parse_mode"] != expected_mode
        )
          invalid_delivery_state!(expected_date)
        end
      end

      def validate_unit!(unit, next_chunk, expected_date)
        valid = unit.is_a?(Hash) &&
                unit["chunk_index"] == next_chunk &&
                unit["payload"].is_a?(String) &&
                !unit["payload"].empty? &&
                %w[markdown_v2 html].include?(unit["parse_mode"]) &&
                unit["payload_sha256"] == ::Digest::SHA256.hexdigest(unit["payload"])
        invalid_delivery_state!(expected_date) unless valid
      end

      def invalid_delivery_state!(expected_date)
        raise PermanentDeliveryCheckpointError,
              "hive digest: corrupt delivery state in checkpoint for #{expected_date}"
      end

      def same_unit?(left, right)
        %w[chunk_index payload parse_mode payload_sha256].all? do |key|
          left[key] == right[key]
        end
      end

      def normalize_date(value)
        date = value.is_a?(Date) ? value : Date.iso8601(value.to_s)
        key = date.iso8601
        unless value.is_a?(Date) || value.to_s == key
          raise ArgumentError
        end

        key
      rescue ArgumentError
        raise PermanentDeliveryCheckpointError,
              "hive digest: delivery checkpoint date must be YYYY-MM-DD; got #{value.inspect}"
      end

      def ensure_root!
        FileUtils.mkdir_p(@root, mode: 0o700)
        File.chmod(0o700, @root)
      end

      def checkpoint_path(key)
        File.join(@root, "#{key}.json")
      end

      def lock_path(key)
        File.join(@root, ".#{key}.lock")
      end

      def timestamp
        @clock.call.utc.iso8601
      end

      def delivery_unit(chunk_index:, payload:, parse_mode:)
        {
          "chunk_index" => chunk_index,
          "payload" => payload,
          "payload_sha256" => ::Digest::SHA256.hexdigest(payload),
          "parse_mode" => parse_mode.to_s
        }
      end

      def checksum(chunks)
        ::Digest::SHA256.hexdigest(JSON.generate(chunks))
      end
    end
  end
end
