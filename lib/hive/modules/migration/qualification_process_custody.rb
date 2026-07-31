require "json"
require "hive/errors"
require "hive/managed_directory"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Cleanup-only custody sidecars for detached qualification wrappers.
      # These identities are never qualification evidence; the trusted host
      # rechecks them against the live process before sending any signal.
      module QualificationProcessCustody
        module_function

        SCHEMA = "hive-patrol-qualification-process-custody".freeze
        SCHEMA_VERSION = 1
        MAX_RECORDS = 64
        MAX_BYTES = 16 * 1024
        ATTEMPT_ID =
          /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
        KEYS = %w[
          attempt_id schema schema_version wrapper
        ].freeze
        WRAPPER_KEYS = %w[
          pid process_group_id session_id start_fingerprint
        ].freeze

        def write(root:, attempt_id:, wrapper:)
          directory = directory(root)
          record = validate(
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "attempt_id" => attempt_id.to_s,
            "wrapper" => wrapper
          )
          relative = "#{record.fetch('attempt_id')}.json"
          existing = directory.read_with_metadata(
            relative,
            max_bytes: MAX_BYTES,
            missing: true
          )
          if existing
            current = load_snapshot(existing)
            return current if current == record

            malformed!
          end
          directory.atomic_write(
            relative,
            canonical(record),
            mode: 0o600,
            expected_absent: true
          )
          record
        rescue Hive::ManagedDirectory::UnsafeError
          malformed!
        end

        def read_all(root:)
          directory = directory(root)
          children = directory.each_child.to_a.sort
          malformed! if
            children.length > MAX_RECORDS ||
              children.any? do |name|
                !name.end_with?(".json") ||
                  !ATTEMPT_ID.match?(
                    name.delete_suffix(".json")
                  )
              end
          children.to_h do |name|
            snapshot = directory.read_with_metadata(
              name,
              max_bytes: MAX_BYTES
            )
            record = load_snapshot(snapshot)
            malformed! unless
              name == "#{record.fetch('attempt_id')}.json"
            [ record.fetch("attempt_id"), record ]
          end.freeze
        rescue Hive::ManagedDirectory::UnsafeError
          malformed!
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def directory(root)
          path = root.to_s
          malformed! unless
            !path.empty? &&
              !path.include?("\0") &&
              path == File.expand_path(path)
          stat = File.lstat(path)
          malformed! unless
            stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o777) == 0o700 &&
              File.realpath(path) == path
          Hive::ManagedDirectory.new(
            root: path,
            label: "patrol qualification process custody"
          )
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR,
               Errno::ELOOP, ArgumentError
          malformed!
        end
        private_class_method :directory

        def load_snapshot(snapshot)
          malformed! unless snapshot.fetch(:mode) == 0o600
          bytes = snapshot.fetch(:bytes)
          value = JSON.parse(bytes)
          malformed! unless bytes == canonical(value)
          validate(value)
        rescue JSON::ParserError, EncodingError, KeyError
          malformed!
        end
        private_class_method :load_snapshot

        def validate(value)
          malformed! unless
            value.is_a?(Hash) &&
              value.keys.all? { |key| key.is_a?(String) } &&
              value.keys.sort == KEYS &&
              value["schema"] == SCHEMA &&
              value["schema_version"] == SCHEMA_VERSION &&
              ATTEMPT_ID.match?(value["attempt_id"].to_s)
          wrapper = value["wrapper"]
          malformed! unless
            wrapper.is_a?(Hash) &&
              wrapper.keys.all? { |key| key.is_a?(String) } &&
              wrapper.keys.sort == WRAPPER_KEYS
          %w[pid session_id process_group_id].each do |key|
            malformed! unless
              wrapper[key].is_a?(Integer) &&
                wrapper[key].positive?
          end
          fingerprint = wrapper["start_fingerprint"]
          malformed! unless
            fingerprint.is_a?(String) &&
              !fingerprint.empty? &&
              fingerprint.bytesize <= 512 &&
              !fingerprint.match?(/[\u0000-\u001f\u007f]/)
          immutable(value)
        end
        private_class_method :validate

        def immutable(value)
          case value
          when Hash
            value.to_h do |key, child|
              [ key.dup.freeze, immutable(child) ]
            end.freeze
          when Array
            value.map { |child| immutable(child) }.freeze
          when String
            value.dup.freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          else
            malformed!
          end
        end
        private_class_method :immutable

        def malformed!
          raise Hive::ConfigError,
                "patrol qualification process custody is unsafe"
        end
        private_class_method :malformed!
      end
    end
  end
end
