require "digest"
require "json"
require "hive/atomic_file"
require "hive/attempts/store"
require "hive/paths"
require "hive/task_projection"
require "hive/task_journal"

module Hive
  class TaskProjection
    class Store
      SNAPSHOT_BASENAME = "task-projection.json".freeze

      attr_reader :task_folder, :journal_path, :snapshot_path, :attempt_store

      def initialize(task_folder:, projector: Hive::TaskProjection, attempt_store: default_attempt_store)
        @task_folder = File.expand_path(task_folder)
        @journal_path = File.join(@task_folder, Hive::TaskJournal::JOURNAL_BASENAME)
        @snapshot_path = File.join(@task_folder, SNAPSHOT_BASENAME)
        @projector = projector
        @attempt_store = attempt_store
      end

      def read(marker: nil)
        snapshot = read_snapshot
        bytes = journal_bytes
        ensure_journal_after_handoff!(snapshot: snapshot, marker: marker, bytes: bytes)
        quick_binding = {
          "cursor" => bytes.bytesize,
          "hash" => ::Digest::SHA256.hexdigest(bytes),
          "event_id" => snapshot&.dig("journal", "event_id")
        }
        if valid?(snapshot, quick_binding) && attempt_bindings_valid?(snapshot)
          projection = Hive::TaskProjection.from_data(snapshot)
          return marker ? projection.with_marker(marker) : projection
        end

        replay(journal_binding(bytes), marker: marker)
      end

      def rebuild!(marker: nil)
        snapshot = read_snapshot
        bytes = journal_bytes
        ensure_journal_after_handoff!(snapshot: snapshot, marker: marker, bytes: bytes)
        binding = journal_binding(bytes)
        projection = replay(binding, marker: marker)
        publish(projection)
        projection
      end

      def publish(projection)
        body = "#{Hive::TaskProjection.canonical_json(projection.to_h)}\n"
        Hive::AtomicFile.write(snapshot_path, body, mode: 0o644)
        Hive::AtomicFile.fsync_directory(task_folder)
        snapshot_path
      end

      def valid?(snapshot, binding = journal_binding)
        return false unless snapshot.is_a?(Hash)
        return false unless snapshot["schema"] == Hive::TaskProjection::SCHEMA
        return false unless snapshot["schema_version"] == Hive::TaskProjection::SCHEMA_VERSION

        journal = snapshot["journal"]
        journal.is_a?(Hash) &&
          journal["cursor"] == binding.fetch("cursor") &&
          journal["hash"] == binding.fetch("hash") &&
          journal["event_id"] == binding.fetch("event_id")
      end

      private

      def replay(binding, marker:)
        @projector.project(
          records: binding.fetch("records"),
          cursor: binding.fetch("cursor"), journal_hash: binding.fetch("hash"), marker: marker
        )
      end

      def journal_binding(bytes = journal_bytes)
        if bytes.empty? && !File.exist?(journal_path)
          return {
            "cursor" => 0, "hash" => ::Digest::SHA256.hexdigest(""),
            "event_id" => nil, "records" => []
          }
        end

        replay = Hive::TaskProjection.replay_journal(bytes, attempt_store: @attempt_store)
        {
          "cursor" => replay.cursor,
          "hash" => replay.ledger_hash,
          "event_id" => replay.record_id,
          "records" => replay.records
        }
      end

      def read_snapshot
        JSON.parse(File.binread(snapshot_path))
      rescue Errno::ENOENT, JSON::ParserError, SystemCallError
        nil
      end

      def journal_bytes
        File.binread(journal_path)
      rescue Errno::ENOENT
        ""
      end

      def attempt_bindings_valid?(snapshot)
        bindings = snapshot.dig("journal", "attempts")
        return false unless bindings.is_a?(Array)

        bindings.all? do |binding|
          next false unless binding.is_a?(Hash) && @attempt_store

          attempt = @attempt_store.fetch(binding["attempt_id"])
          task = binding["task"]
          attempt && task.is_a?(Hash) &&
            attempt["task_slug"] == task["slug"] &&
            (task["id"].nil? || attempt["task_id"].to_s == task["id"].to_s) &&
            attempt["intended_stage"] == binding["stage"] &&
            attempt.task_input_epoch == binding["task_generation"] &&
            attempt_value(attempt, :state) == binding["state"] &&
            attempt_value(attempt, :outcome) == binding["outcome"] &&
            attempt_value(attempt, :lease_version) == binding["lease_version"] &&
            attempt["accepted_at"] == binding["accepted_at"] &&
            attempt["predecessor_attempt_id"] == binding["predecessor_attempt_id"] &&
            (binding["ownership_generation"].nil? ||
             attempt.ownership_generation == binding["ownership_generation"])
        end
      rescue Hive::Error, SystemCallError, IOError
        false
      end

      def attempt_value(attempt, name)
        attempt.respond_to?(name) ? attempt.public_send(name) : attempt[name.to_s]
      end

      def durable_handoff_snapshot?(snapshot)
        return false unless snapshot.is_a?(Hash)

        ids = [ snapshot.dig("identity", "attempt_id") ] +
              Array(snapshot.dig("journal", "attempts")).filter_map do |binding|
                binding["attempt_id"] if binding.is_a?(Hash)
              end
        ids.any? do |attempt_id|
          !attempt_id.to_s.empty? && attempt_id != Hive::TaskJournal::LEGACY_ATTEMPT_ID
        end
      end

      def durable_handoff_marker?(marker)
        return false unless marker

        name = marker.respond_to?(:name) ? marker.name : marker.fetch("name", nil)
        return false unless name.to_s.start_with?("execute_")

        attrs = marker.respond_to?(:attrs) ? marker.attrs : marker.fetch("attrs", {})
        attempt_id = attrs.to_h["attempt_id"] || attrs.to_h[:attempt_id]
        !attempt_id.to_s.empty? && attempt_id != Hive::TaskJournal::LEGACY_ATTEMPT_ID
      end

      def ensure_journal_after_handoff!(snapshot:, marker:, bytes:)
        return unless bytes.empty?
        return unless durable_handoff_snapshot?(snapshot) || durable_handoff_marker?(marker)

        raise Hive::TaskProjection::InvalidJournal,
              "authoritative task journal is missing or empty after durable handoff"
      end

      def default_attempt_store
        root = ENV["HIVE_ATTEMPT_STORE_ROOT"].to_s
        Hive::Attempts::Store.new(
          root: root.empty? ? Hive::Paths.attempts_root : root,
          create_directories: false
        )
      end
    end
  end
end
