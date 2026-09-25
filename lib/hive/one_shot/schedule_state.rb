require "json"
require "time"
require "fileutils"
require "hive/atomic_file"
require "hive/errors"

module Hive
  module OneShot
    class ScheduleState
      SCHEMA = "hive-scheduler-checkpoint".freeze
      SCHEMA_VERSION = 1
      ROOT_KEYS = %w[components schema schema_version updated_at].freeze

      class StateError < Hive::Error
        attr_reader :code

        def initialize(message, code:)
          @code = code
          super(message)
        end
      end

      attr_reader :path

      def initialize(state_root:)
        @directory = File.join(File.expand_path(state_root), "scheduler")
        @path = File.join(@directory, "checkpoint.json")
        @lock_path = File.join(@directory, ".checkpoint.lock")
      end

      def read(component)
        with_lock do
          deep_copy(load_document.fetch("components").fetch(component.to_s, {}))
        end
      end

      def update(component, now: Time.now.utc)
        with_lock do
          document = load_document
          current = deep_copy(document.fetch("components").fetch(component.to_s, {}))
          replacement = yield(current)
          invalid!("component state must be an object") unless replacement.is_a?(Hash)
          validate_deadlines!(replacement)
          document.fetch("components")[component.to_s] = replacement
          document["updated_at"] = now.utc.iso8601(6)
          persist(document)
          deep_copy(replacement)
        end
      end

      private

      def with_lock
        FileUtils.mkdir_p(@directory, mode: 0o700)
        File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      rescue StateError
        raise
      rescue SystemCallError, IOError => error
        raise StateError.new("scheduler checkpoint unavailable: #{error.message}", code: "checkpoint_unavailable")
      end

      def load_document
        return empty_document unless File.file?(path)

        document = JSON.parse(File.binread(path))
        invalid!("root shape is invalid") unless document.is_a?(Hash) &&
          document.keys.sort == ROOT_KEYS && document["schema"] == SCHEMA &&
          document["components"].is_a?(Hash)
        version = document["schema_version"]
        unless version == SCHEMA_VERSION
          code = version.is_a?(Integer) && version > SCHEMA_VERSION ?
            "checkpoint_newer_schema" : "checkpoint_corrupt"
          raise StateError.new("unsupported scheduler checkpoint schema #{version.inspect}", code: code)
        end
        Time.iso8601(document.fetch("updated_at"))
        document.fetch("components").each_value do |component|
          invalid!("component state must be an object") unless component.is_a?(Hash)
          validate_deadlines!(component)
        end
        document
      rescue JSON::ParserError, ArgumentError, KeyError, TypeError => error
        raise StateError.new("scheduler checkpoint is corrupt: #{error.message}", code: "checkpoint_corrupt")
      end

      def empty_document
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "updated_at" => Time.at(0).utc.iso8601(6), "components" => {}
        }
      end

      def validate_deadlines!(value)
        value.each do |key, child|
          invalid!("component keys must be strings") unless key.is_a?(String)
          if key.end_with?("_at") && !child.nil?
            Time.iso8601(child.to_s)
          elsif child.is_a?(Hash)
            validate_deadlines!(child)
          elsif child.is_a?(Array)
            child.each { |entry| validate_deadlines!(entry) if entry.is_a?(Hash) }
          end
        rescue ArgumentError
          invalid!("#{key} must be an absolute RFC3339 timestamp")
        end
      end

      def invalid!(message)
        raise StateError.new("scheduler checkpoint is invalid: #{message}", code: "checkpoint_invalid")
      end

      def persist(document)
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(document)}\n", mode: 0o600)
        Hive::AtomicFile.fsync_directory(@directory)
      rescue JSON::GeneratorError, TypeError => error
        invalid!(error.message)
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
