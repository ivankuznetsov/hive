require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/attempts/record"
require "hive/paths"

module Hive
  module Recovery
    # One pre-1.0 cutover for durable recovery state. Runtime readers accept
    # only the current schemas; this migration owns every older persisted
    # shape and leaves a receipt after the whole state home is current.
    class Migration
      class Error < Hive::Error; end

      RECEIPT_SCHEMA = "hive-recovery-migration"
      RECEIPT_VERSION = 2
      RECEIPT_BASENAME = "recovery-migration-v2.json"
      LOCK_BASENAME = ".recovery-migration-v2.lock"
      LEGACY_ATTEMPT_VERSION = 1
      CURRENT_ATTEMPT_VERSION = Hive::Attempts::Record::SCHEMA_VERSION
      CURRENT_REQUEST_VERSION = 4
      CURRENT_RESULT_VERSION = 2
      RECEIPT_REQUIRED_KEYS = %w[
        completed_at attempts dispatch_requests dispatch_results
      ].freeze

      attr_reader :state_home

      def self.ensure!(state_home: Hive::Paths.state_home, now: Time.now.utc)
        new(state_home: state_home).call(now: now)
      end

      def initialize(state_home:)
        @state_home = File.expand_path(state_home)
      end

      def call(now: Time.now.utc)
        return empty_result unless migration_state_present?

        FileUtils.mkdir_p(state_home, mode: 0o700)
        File.chmod(0o700, state_home)
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          return read_receipt if complete?

          result = {
            "schema" => RECEIPT_SCHEMA,
            "schema_version" => RECEIPT_VERSION,
            "completed_at" => now.utc.iso8601(6),
            "attempts" => migrate_attempts!,
            "dispatch_requests" => migrate_dispatch_requests!,
            "dispatch_results" => migrate_dispatch_results!
          }
          Hive::AtomicFile.write(receipt_path, JSON.generate(result) + "\n", mode: 0o600)
          Hive::AtomicFile.fsync_directory(state_home)
          result
        end
      rescue JSON::ParserError, SystemCallError, IOError, Hive::Attempts::InvalidRecord => e
        raise Error, "recovery migration failed: #{e.message}"
      end

      private

      def migration_state_present?
        [
          legacy_attempt_root, current_attempt_root,
          dispatch_requests_root, dispatch_results_root,
          receipt_path
        ].any? { |path| File.exist?(path) }
      end

      def complete?
        File.file?(receipt_path) && !File.exist?(legacy_attempt_root)
      end

      def read_receipt
        data = JSON.parse(File.binread(receipt_path))
        unless data.is_a?(Hash) &&
               data["schema"] == RECEIPT_SCHEMA &&
               data["schema_version"] == RECEIPT_VERSION &&
               data["completed_at"].is_a?(String) &&
               RECEIPT_REQUIRED_KEYS.drop(1).all? { |key| data[key].is_a?(Hash) }
          raise Error, "recovery migration receipt is invalid"
        end

        data
      end

      def migrate_attempts!
        if File.exist?(legacy_attempt_root) && File.exist?(current_attempt_root)
          unless remove_empty_legacy_attempt_skeleton!
            raise Error,
                  "both legacy and current attempt roots exist; preserve them and resolve " \
                  "#{legacy_attempt_root} versus #{current_attempt_root} before retrying"
          end
        end

        if File.exist?(legacy_attempt_root)
          preflight_legacy_attempt_root!
          FileUtils.mkdir_p(File.dirname(current_attempt_root), mode: 0o700)
          File.rename(legacy_attempt_root, current_attempt_root)
          Hive::AtomicFile.fsync_directory(File.dirname(current_attempt_root))
        end
        return attempt_count_result unless File.directory?(current_attempt_records_root)

        migrated = 0
        normalized = 0
        archived = 0
        Dir.glob(File.join(current_attempt_records_root, "*.json")).sort.each do |path|
          data = parse_object!(path)
          unless data["schema"] == Hive::Attempts::Record::SCHEMA
            raise Error, "#{path} is not a #{Hive::Attempts::Record::SCHEMA} record"
          end

          if data["compatibility"] == true
            unless %w[terminal lost].include?(data["state"])
              raise Error,
                    "live legacy compatibility attempt #{data['attempt_id']} must finish " \
                    "before the v2 cutover"
            end
            archive_compatibility_record!(path)
            archived += 1
            next
          end

          source_version = data["schema_version"]
          case source_version
          when LEGACY_ATTEMPT_VERSION
            data["ownership_generation"] ||= data["task_generation"]
            data["task_input_epoch"] = 0 unless data.key?("task_input_epoch")
            receipt = data["receipt"]
            if receipt.is_a?(Hash)
              receipt["ownership_generation"] ||= data["ownership_generation"]
              receipt["task_input_epoch"] = data["task_input_epoch"] unless receipt.key?("task_input_epoch")
            end
            data["schema_version"] = CURRENT_ATTEMPT_VERSION
            migrated += 1
          when CURRENT_ATTEMPT_VERSION
            normalized += 1 if data.key?("compatibility")
          else
            raise Error, "#{path} has unsupported attempt schema #{source_version.inspect}"
          end

          data.delete("compatibility")
          record = Hive::Attempts::Record.new(data)
          write_json!(path, record.to_h)
        end
        attempt_count_result(migrated: migrated, normalized: normalized, archived: archived)
      end

      # A pre-cutover reader can recreate the old store's directory skeleton
      # after v2 has already become authoritative. Remove only a tree made
      # entirely of empty real directories. Any file, symlink, or concurrent
      # writer makes rmdir fail closed and preserves the ambiguous root.
      def remove_empty_legacy_attempt_skeleton!
        directories = []
        pending = [ legacy_attempt_root ]
        until pending.empty?
          directory = pending.pop
          return false unless File.lstat(directory).directory?

          directories << directory
          Dir.children(directory).each do |entry|
            path = File.join(directory, entry)
            return false unless File.lstat(path).directory?

            pending << path
          end
        end

        directories.sort_by { |path| -path.count(File::SEPARATOR) }.each do |directory|
          Dir.rmdir(directory)
        end
        Hive::AtomicFile.fsync_directory(attempts_parent)
        true
      rescue Errno::ENOENT, Errno::ENOTEMPTY
        !File.exist?(legacy_attempt_root)
      end

      # Detached supervisors admitted by the old binary retain an explicit
      # attempts/v1 store path. Moving that tree while one is live would make
      # its next heartbeat recreate v1 beside v2. Wait for every old-root
      # owner to terminalize before the atomic directory rename.
      def preflight_legacy_attempt_root!
        records_root = File.join(legacy_attempt_root, "records")
        return unless File.directory?(records_root)

        Dir.children(records_root).sort.each do |basename|
          next unless basename.end_with?(".json")

          data = parse_object!(File.join(records_root, basename))
          next unless %w[launching running].include?(data["state"])

          label = data["compatibility"] == true ? "live legacy compatibility attempt" :
            "live attempt in the legacy root"
          raise Error,
                "#{label} #{data['attempt_id']} must finish before the v2 cutover"
        end
      rescue Errno::ENOENT
        nil
      end

      def migrate_dispatch_requests!
        migrated = 0
        each_queue_document(dispatch_requests_root, include_claimed: true) do |path, data|
          next unless data["schema"] == "hive-dispatch-request"

          version = data["schema_version"]
          next if version == CURRENT_REQUEST_VERSION
          next unless [ 1, 2, 3 ].include?(version)

          data["task_generation"] = nil unless data.key?("task_generation")
          data["predecessor_attempt_id"] = nil unless data.key?("predecessor_attempt_id")
          data["inherited_outputs"] = [] unless data.key?("inherited_outputs")
          data["recovery"] = nil unless data.key?("recovery")
          data["schema_version"] = CURRENT_REQUEST_VERSION
          write_json!(path, data)
          migrated += 1
        end
        { "migrated" => migrated }
      end

      def migrate_dispatch_results!
        migrated = 0
        each_queue_document(dispatch_results_root) do |path, data|
          next unless data["schema"] == "hive-dispatch-result"

          version = data["schema_version"]
          next if version == CURRENT_RESULT_VERSION
          next unless version == 1

          data["attempt_id"] = nil unless data.key?("attempt_id")
          data["attempt_state"] = nil unless data.key?("attempt_state")
          data["receipt"] = nil unless data.key?("receipt")
          data["schema_version"] = CURRENT_RESULT_VERSION
          write_json!(path, data)
          migrated += 1
        end
        { "migrated" => migrated }
      end

      def each_queue_document(root, include_claimed: false)
        return unless File.directory?(root)

        suffixes = [ ".json" ]
        suffixes << ".json.claimed" if include_claimed
        entries = Dir.children(root).select do |basename|
          suffixes.any? { |suffix| basename.end_with?(suffix) }
        end
        entries.sort.each do |basename|
          path = File.join(root, basename)
          data = parse_queue_object(path)
          yield path, data if data
        end
      rescue Errno::ENOENT
        nil
      end

      def archive_compatibility_record!(path)
        FileUtils.mkdir_p(compatibility_archive_root, mode: 0o700)
        File.chmod(0o700, compatibility_archive_root)
        destination = File.join(compatibility_archive_root, File.basename(path))
        if File.exist?(destination)
          raise Error, "legacy compatibility archive collision at #{destination}"
        end

        File.rename(path, destination)
        File.chmod(0o600, destination)
        Hive::AtomicFile.fsync_directory(compatibility_archive_root)
        Hive::AtomicFile.fsync_directory(current_attempt_records_root)
      end

      def parse_object!(path)
        data = JSON.parse(File.binread(path))
        raise Error, "#{path} must contain a JSON object" unless data.is_a?(Hash)

        data
      end

      # Malformed queue deliveries remain for the queue's existing bad-file
      # handler. They carry no trustworthy schema to migrate and must not
      # prevent unrelated durable ownership state from cutting over.
      def parse_queue_object(path)
        data = JSON.parse(File.binread(path))
        data if data.is_a?(Hash)
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      def write_json!(path, data)
        Hive::AtomicFile.write(path, JSON.generate(data) + "\n", mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def attempt_count_result(migrated: 0, normalized: 0, archived: 0)
        {
          "migrated" => migrated,
          "normalized" => normalized,
          "archived_legacy_compatibility" => archived
        }
      end

      def empty_result
        {
          "schema" => RECEIPT_SCHEMA,
          "schema_version" => RECEIPT_VERSION,
          "status" => "not_needed"
        }
      end

      def attempts_parent = File.join(state_home, "attempts")
      def legacy_attempt_root = File.join(attempts_parent, "v1")
      def current_attempt_root = File.join(attempts_parent, "v2")
      def current_attempt_records_root = File.join(current_attempt_root, "records")
      def compatibility_archive_root = File.join(attempts_parent, "legacy-v1-records")
      def dispatch_requests_root = File.join(state_home, "dispatch_requests")
      def dispatch_results_root = File.join(state_home, "dispatch_results")
      def receipt_path = File.join(state_home, RECEIPT_BASENAME)
      def lock_path = File.join(state_home, LOCK_BASENAME)
    end
  end
end
