require "json"
require "time"
require "hive/atomic_file"
require "hive/paths"
require "hive/runtime_control_plane"

module Hive
  module Daemon
    ProofVerdict = Data.define(:valid, :reason, :payload) do
      def valid? = valid == true
    end

    # Crash-durable acknowledgement written only after SQLite has completed a
    # checked FULL checkpoint and closed its connection.
    class FinalizationProof
      SCHEMA = "hive-runtime-quiescence-proof".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = 16 * 1024 * 1024
      KEYS = %w[
        schema schema_version installation_id generation lifecycle_revision
        mutation_sequence interrupted_attempt_ids inventory checkpoint published_at
      ].freeze

      attr_reader :path

      def initialize(state_home: Hive::Paths.state_home, writer: Hive::AtomicFile,
                     json: JSON)
        @path = Hive::Paths.runtime_quiescence_proof_path(File.expand_path(state_home))
        @writer = writer
        @json = json
      end

      def publish!(lifecycle:, installation_id:, checkpoint:, interrupted_attempt_ids:,
                   inventory:, published_at: Time.now.utc)
        payload = {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "installation_id" => installation_id.to_s,
          "generation" => Integer(lifecycle.generation),
          "lifecycle_revision" => Integer(lifecycle.revision),
          "mutation_sequence" => Integer(lifecycle.mutation_sequence),
          "interrupted_attempt_ids" => Array(interrupted_attempt_ids).map(&:to_s).uniq.sort,
          "inventory" => Array(inventory).map { |entry| stringify(entry) },
          "checkpoint" => stringify(checkpoint),
          "published_at" => published_at.utc.iso8601(6)
        }
        bytes = "#{@json.generate(payload)}\n"
        raise IOError, "runtime quiescence proof exceeds its size bound" if bytes.bytesize > MAX_BYTES
        @writer.write(path, bytes, mode: 0o600, fsync: true)
        @writer.fsync_directory(File.dirname(path))
        payload.freeze
      rescue StandardError
        begin
          File.delete(path) if File.file?(path) && !File.symlink?(path)
          @writer.fsync_directory(File.dirname(path)) if File.directory?(File.dirname(path))
        rescue StandardError
          nil
        end
        raise
      end

      def verify(lifecycle:, installation_id:)
        payload = read
        return payload if payload.is_a?(ProofVerdict)
        return invalid("installation_mismatch", payload) unless
          payload.fetch("installation_id") == installation_id.to_s
        return invalid("generation_mismatch", payload) unless
          payload.fetch("generation") == lifecycle.generation
        return invalid("revision_mismatch", payload) unless
          payload.fetch("lifecycle_revision") == lifecycle.revision
        return invalid("mutation_sequence_mismatch", payload) unless
          payload.fetch("mutation_sequence") == lifecycle.mutation_sequence
        return invalid("interrupted_attempts_mismatch", payload) unless
          payload.fetch("interrupted_attempt_ids").sort == lifecycle.interrupted_attempt_ids.sort
        return invalid("lifecycle_not_paused", payload) unless lifecycle.phase == "paused"

        ProofVerdict.new(valid: true, reason: nil, payload: payload)
      end

      def read
        return invalid("proof_missing") unless File.exist?(path) || File.symlink?(path)
        status = File.lstat(path)
        unless status.file? && !status.symlink? && status.uid == Process.uid &&
               status.nlink == 1 && (status.mode & 0o077).zero? && status.size <= MAX_BYTES
          return invalid("proof_custody_invalid")
        end
        payload = @json.parse(File.binread(path))
        validate!(payload)
        payload
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError,
             SystemCallError, IOError
        invalid("proof_invalid")
      end

      def remove!
        return false unless File.exist?(path) || File.symlink?(path)
        status = File.lstat(path)
        unless status.file? && !status.symlink? && status.uid == Process.uid && status.nlink == 1
          raise Hive::RuntimeControlPlane::IntegrityError.new(
            "runtime quiescence proof has unsafe custody", code: :proof_custody_invalid,
            action: Hive::RuntimeControlPlane::Database::BACKUP_ACTION
          )
        end
        File.delete(path)
        @writer.fsync_directory(File.dirname(path))
        true
      end

      private

      def validate!(payload)
        raise ArgumentError unless payload.is_a?(Hash) && payload.keys.sort == KEYS.sort
        raise ArgumentError unless payload.fetch("schema") == SCHEMA
        raise ArgumentError unless payload.fetch("schema_version") == SCHEMA_VERSION
        %w[generation lifecycle_revision mutation_sequence].each do |key|
          raise ArgumentError unless payload.fetch(key).is_a?(Integer) && payload.fetch(key) >= 0
        end
        raise ArgumentError unless payload.fetch("installation_id").is_a?(String) &&
          !payload.fetch("installation_id").empty?
        interrupted = payload.fetch("interrupted_attempt_ids")
        raise ArgumentError unless interrupted.is_a?(Array) &&
          interrupted.all? { |attempt_id| attempt_id.is_a?(String) && !attempt_id.empty? }
        inventory = payload.fetch("inventory")
        raise ArgumentError unless inventory.is_a?(Array) && inventory.all? { |item| item.is_a?(Hash) }
        checkpoint = payload.fetch("checkpoint")
        raise ArgumentError unless checkpoint.is_a?(Hash) && checkpoint["complete"] == true
        %w[busy log_frames checkpointed_frames].each do |key|
          raise ArgumentError unless checkpoint[key].is_a?(Integer) && checkpoint[key] >= 0
        end
        raise ArgumentError unless checkpoint["busy"].zero? &&
          checkpoint["checkpointed_frames"] >= checkpoint["log_frames"]
        Time.iso8601(payload.fetch("published_at"))
        true
      end

      def invalid(reason, payload = nil)
        ProofVerdict.new(valid: false, reason: reason, payload: payload)
      end

      def stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end
  end
end
