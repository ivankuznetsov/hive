require "fileutils"
require "json"
require "hive/atomic_file"
require "hive/modules/migration/occurrence_record_validator"

module Hive
  module Modules
    module Migration
      # The sole lock/read/write owner for canonical occurrence records.
      class OccurrenceRecordStore
        include OccurrenceContract

        attr_reader :root

        def initialize(root:, validator:)
          @root = File.expand_path(root)
          @validator = validator
        end

        def fetch(occurrence_id)
          id = @validator.occurrence_id(occurrence_id)
          with_lock(id, shared: true) do
            path = occurrence_path(id)
            next nil unless File.file?(path)

            read(path, expected_id: id)
          end
        end

        def records
          occurrence_paths.map do |path|
            record = read(
              path, expected_id: File.basename(path, ".json")
            )
            @validator.copy(record).freeze
          end.freeze
        end

        def mutate(occurrence_id, create: false)
          id = @validator.occurrence_id(occurrence_id)
          with_lock(id) do
            path = occurrence_path(id)
            record = File.file?(path) ?
              read(path, expected_id: id) : nil
            if record.nil? && !create
              malformed!("patrol occurrence is missing")
            end
            replacement = yield(
              record && @validator.copy(record)
            )
            @validator.validate!(replacement, expected_id: id)
            bytes = @validator.canonical(replacement)
            if bytes.bytesize > MAX_RECORD_BYTES
              malformed!(
                "patrol occurrence exceeds the bounded size"
              )
            end
            Hive::AtomicFile.write(path, bytes, mode: 0o600)
            Hive::AtomicFile.fsync_directory(File.dirname(path))
            replacement
          end
        rescue SystemCallError, IOError => e
          raise Hive::ConfigError,
                "patrol occurrence store is unavailable: #{e.message}"
        end

        private

        def read(path, expected_id:)
          bytes = bounded_regular_read(path)
          data = JSON.parse(bytes)
          unless bytes == @validator.canonical(data)
            malformed!("patrol occurrence is not canonical")
          end
          @validator.validate!(data, expected_id: expected_id)
          data.freeze
        rescue JSON::ParserError, EncodingError
          malformed!("patrol occurrence is malformed")
        end

        def bounded_regular_read(path)
          stat = File.lstat(path)
          unless stat.file? && !stat.symlink? &&
                 stat.size <= MAX_RECORD_BYTES
            malformed!("patrol occurrence is malformed")
          end
          flags = File::RDONLY
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(path, flags) do |io|
            current = io.stat
            unless current.file? &&
                   current.dev == stat.dev &&
                   current.ino == stat.ino
              malformed!("patrol occurrence is malformed")
            end
            bytes = io.read(MAX_RECORD_BYTES + 1)
            if bytes.nil? || bytes.bytesize > MAX_RECORD_BYTES
              malformed!("patrol occurrence is malformed")
            end
            bytes
          end
        end

        def occurrence_paths
          return [] unless File.exist?(root)

          stat = File.lstat(root)
          unless stat.directory? && !stat.symlink?
            malformed!("patrol occurrence store is malformed")
          end
          paths = []
          Dir.each_child(root) do |name|
            next unless name.match?(
              /\Aocc-[0-9a-f]{64}\.json\z/
            )

            paths << File.join(root, name)
            if paths.size > 4_096
              malformed!(
                "patrol occurrence history exceeds the bounded limit"
              )
            end
          end
          paths.sort
        rescue SystemCallError => e
          raise Hive::ConfigError,
                "patrol occurrence store is unavailable: #{e.message}"
        end

        def with_lock(occurrence_id, shared: false)
          FileUtils.mkdir_p(root, mode: 0o700)
          File.open(
            "#{occurrence_path(occurrence_id)}.lock",
            File::RDWR | File::CREAT,
            0o600
          ) do |lock|
            lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
            yield
          ensure
            lock&.flock(File::LOCK_UN)
          end
        end

        def occurrence_path(occurrence_id)
          File.join(
            root, "#{@validator.occurrence_id(occurrence_id)}.json"
          )
        end

        def malformed!(message)
          raise Hive::ConfigError, message
        end
      end
    end
  end
end
