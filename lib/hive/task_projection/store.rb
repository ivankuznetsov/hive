require "digest"
require "json"
require "hive/atomic_file"
require "hive/task_projection"
require "hive/task_journal"

module Hive
  class TaskProjection
    class Store
      SNAPSHOT_BASENAME = "task-projection.json".freeze

      attr_reader :task_folder, :journal_path, :snapshot_path

      def initialize(task_folder:, projector: Hive::TaskProjection)
        @task_folder = File.expand_path(task_folder)
        @journal_path = File.join(@task_folder, Hive::TaskJournal::JOURNAL_BASENAME)
        @snapshot_path = File.join(@task_folder, SNAPSHOT_BASENAME)
        @projector = projector
      end

      def read(marker: nil)
        binding = journal_binding
        snapshot = read_snapshot
        return Hive::TaskProjection.allocate.tap { |projection| projection.instance_variable_set(:@data, snapshot) } if valid?(snapshot, binding)

        replay(binding, marker: marker)
      end

      def rebuild!(marker: nil)
        binding = journal_binding
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
          records: Hive::TaskProjection.read_journal(journal_path),
          cursor: binding.fetch("cursor"), journal_hash: binding.fetch("hash"), marker: marker
        )
      end

      def journal_binding
        return { "cursor" => 0, "hash" => Digest::SHA256.hexdigest(""), "event_id" => nil } unless File.exist?(journal_path)

        bytes = File.binread(journal_path)
        event_id = bytes.lines.reverse_each.filter_map do |line|
          JSON.parse(line)["event_id"]
        rescue JSON::ParserError
          nil
        end.first
        { "cursor" => bytes.bytesize, "hash" => Digest::SHA256.hexdigest(bytes), "event_id" => event_id }
      end

      def read_snapshot
        JSON.parse(File.binread(snapshot_path))
      rescue Errno::ENOENT, JSON::ParserError, SystemCallError
        nil
      end
    end
  end
end
