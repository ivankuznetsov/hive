require "json"
require "fileutils"
require "securerandom"
require "time"
require "hive/atomic_file"

module Hive
  module Patrol
    # Shared persistence for ordinary and architecture patrol's legacy
    # reporting state. The namespaces and domain records stay separate; only
    # their identical JSON lifecycle lives here.
    class BaseStateStore
      attr_reader :project_root, :hive_state_path, :root

      def initialize(project_root, state_directory:, collections:, hive_state_path: nil)
        @project_root = File.expand_path(project_root)
        @hive_state_path = File.expand_path(
          hive_state_path || ".hive-state", @project_root
        )
        @root = File.join(@hive_state_path, state_directory)
        @collections = collections.freeze
      end

      def ensure!
        @collections.each { |name| FileUtils.mkdir_p(File.join(root, name)) }
      end

      def state
        read_json(File.join(root, "state.json"))
      end

      def update_state(data)
        write_json(File.join(root, "state.json"), state.merge(data))
      end

      def fingerprints
        read_json(File.join(root, "fingerprints.json"))
      end

      def write_fingerprints(data)
        write_json(File.join(root, "fingerprints.json"), data)
      end

      def dismissed
        read_json(File.join(root, "dismissed.json"))
      end

      def write_dismissed(data)
        write_json(File.join(root, "dismissed.json"), data)
      end

      def run_dir(prefix)
        ensure!
        path = File.join(root, "runs", "#{prefix}-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(path)
        path
      end

      def write_run_log(id, data)
        write_json(File.join(root, "runs", "#{id}.json"), data)
      end

      def write_json(path, data)
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(data)}\n", fsync: false)
        data
      end

      def read_json(path)
        return {} unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      protected

      def write_record(collection, record)
        write_json(File.join(root, collection, "#{record.id}.json"), record.to_h)
      end
    end
  end
end
