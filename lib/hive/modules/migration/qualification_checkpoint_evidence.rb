require "digest"
require "hive/errors"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Host-owned, bounded evidence for durable state observed between
      # qualification process generations. The candidate never supplies or
      # validates these snapshots.
      class QualificationCheckpointEvidence
        ERROR =
          "patrol qualification checkpoint evidence is malformed".freeze
        SNAPSHOT_SCHEMA =
          "hive-patrol-qualification-state-snapshot".freeze
        CHECKPOINT_SCHEMA =
          "hive-patrol-qualification-checkpoint-evidence".freeze
        SCHEMA_VERSION = 1
        MAX_ROOTS = 16
        MAX_ENTRIES = 4_096
        MAX_DEPTH = 32
        MAX_PATH_BYTES = 4_096
        MAX_FILE_BYTES = 4 * 1024 * 1024
        MAX_TOTAL_BYTES = 32 * 1024 * 1024
        MAX_FACT_BYTES = 64 * 1024
        MAX_FACT_NODES = 1_024
        MAX_FACT_DEPTH = 12
        MAX_FACT_STRING_BYTES = 8 * 1024
        MAX_SNAPSHOT_NODES = (MAX_ENTRIES * 8) + 256
        DIGEST = /\A[0-9a-f]{64}\z/
        ROOT_NAME = /\A[a-z][a-z0-9_-]{0,63}\z/
        FACT_KEY = /\A[a-z][a-z0-9_]{0,127}\z/
        CHECKPOINTS = %w[
          after_effect_intent
          after_legacy_capture
          after_legacy_decision
          after_module_decision
          before_effect_settlement
          during_reconciliation
          reconciliation_failure
        ].freeze
        SNAPSHOT_KEYS = %w[
          entry_count file_count root_count roots sandbox_root_sha256
          schema schema_version snapshot_sha256 total_bytes
        ].freeze
        SNAPSHOT_ROOT_KEYS = %w[
          entries name path_sha256 state
        ].freeze
        DIRECTORY_ENTRY_KEYS = %w[mode path type].freeze
        FILE_ENTRY_KEYS = %w[mode path sha256 size type].freeze
        CHECKPOINT_KEYS = %w[
          checkpoint evidence_sha256 facts schema schema_version
          state_sha256
        ].freeze

        Snapshot = Data.define(:payload) do
          def self.from_h(value)
            QualificationCheckpointEvidence.snapshot_from_h(value)
          end

          def to_h = payload
          def sha256 = payload.fetch("snapshot_sha256")
          def roots = payload.fetch("roots")
          def root_count = payload.fetch("root_count")
          def entry_count = payload.fetch("entry_count")
          def file_count = payload.fetch("file_count")
          def total_bytes = payload.fetch("total_bytes")
        end

        Checkpoint = Data.define(:payload) do
          def self.from_h(value)
            QualificationCheckpointEvidence.checkpoint_from_h(value)
          end

          def to_h = payload
          def checkpoint = payload.fetch("checkpoint")
          def state_sha256 = payload.fetch("state_sha256")
          def facts = payload.fetch("facts")
          def sha256 = payload.fetch("evidence_sha256")
        end

        class << self
          def snapshot_from_h(value)
            new.__send__(:snapshot_from_h, value)
          end

          def checkpoint_from_h(value)
            new.__send__(:checkpoint_from_h, value)
          end
        end

        def capture(sandbox_root:, roots:)
          sandbox = validated_sandbox_root(sandbox_root)
          configured_roots = validated_roots(sandbox, roots)
          counters = {
            entries: 0,
            files: 0,
            bytes: 0
          }
          rows = configured_roots.map do |name, path|
            capture_root(
              name,
              path,
              counters
            )
          end.freeze
          body = {
            "schema" => SNAPSHOT_SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "sandbox_root_sha256" =>
              Digest::SHA256.hexdigest(sandbox),
            "roots" => rows,
            "root_count" => rows.length,
            "entry_count" => counters.fetch(:entries),
            "file_count" => counters.fetch(:files),
            "total_bytes" => counters.fetch(:bytes)
          }
          snapshot_from_h(
            body.merge(
              "snapshot_sha256" =>
                digest("qualification-state-snapshot", body)
            )
          )
        rescue Hive::ConfigError
          raise
        rescue ArgumentError, EncodingError, IOError, SystemCallError,
               TypeError
          malformed!
        end

        def bind(checkpoint:, snapshot:, facts:)
          checkpoint = validated_checkpoint(checkpoint)
          snapshot = validated_snapshot(snapshot)
          facts = validated_facts(facts)
          body = {
            "schema" => CHECKPOINT_SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "checkpoint" => checkpoint,
            "state_sha256" => snapshot.sha256,
            "facts" => facts
          }
          checkpoint_from_h(
            body.merge(
              "evidence_sha256" =>
                digest("qualification-checkpoint-evidence", body)
            )
          )
        rescue Hive::ConfigError
          raise
        rescue ArgumentError, EncodingError, KeyError, NoMethodError,
               TypeError
          malformed!
        end

        def verify!(value, checkpoint:, snapshot:)
          evidence =
            value.is_a?(Checkpoint) ?
              checkpoint_from_h(value.to_h) :
              checkpoint_from_h(value)
          expected = validated_checkpoint(checkpoint)
          state = validated_snapshot(snapshot)
          malformed! unless
            evidence.checkpoint == expected &&
              evidence.state_sha256 == state.sha256

          evidence
        rescue Hive::ConfigError
          raise
        rescue ArgumentError, EncodingError, KeyError, NoMethodError,
               TypeError
          malformed!
        end

        private

        def validated_sandbox_root(value)
          malformed! unless value.is_a?(String) &&
                            value == File.expand_path(value)
          path = File.realpath(value)
          stat = File.lstat(path)
          malformed! unless path == value &&
                            safe_directory?(stat)

          path.dup.freeze
        end

        def validated_roots(sandbox, value)
          malformed! unless value.is_a?(Hash) &&
                            value.length.between?(1, MAX_ROOTS)
          roots = value.map do |name, path|
            malformed! unless
              name.is_a?(String) &&
                ROOT_NAME.match?(name) &&
                path.is_a?(String) &&
                path == File.expand_path(path) &&
                descendant?(path, sandbox)
            validate_path_ancestry!(path, sandbox)
            [ name.dup.freeze, path.dup.freeze ]
          end.sort_by(&:first)
          names = roots.map(&:first)
          paths = roots.map(&:last)
          malformed! unless names.uniq.length == names.length &&
                            paths.uniq.length == paths.length
          paths.combination(2) do |left, right|
            malformed! if descendant?(left, right) ||
                          descendant?(right, left)
          end

          roots.freeze
        end

        def validate_path_ancestry!(path, sandbox)
          relative = path.delete_prefix("#{sandbox}/")
          current = sandbox
          relative.split(File::SEPARATOR).each_with_index do |part, index|
            malformed! if part.empty? || part == "." || part == ".."
            current = File.join(current, part)
            break unless File.exist?(current) || File.symlink?(current)

            stat = File.lstat(current)
            malformed! if stat.symlink?
            unless index == relative.split(File::SEPARATOR).length - 1
              malformed! unless stat.directory?
            end
          end
        end

        def descendant?(path, root)
          path.start_with?("#{root}#{File::SEPARATOR}")
        end

        def capture_root(name, path, counters)
          unless File.exist?(path) || File.symlink?(path)
            return {
              "name" => name,
              "path_sha256" => Digest::SHA256.hexdigest(path),
              "state" => "absent".freeze,
              "entries" => [].freeze
            }.freeze
          end
          stat = File.lstat(path)
          malformed! unless safe_directory?(stat)
          entries = []
          walk_directory(
            path,
            ".",
            depth: 0,
            entries: entries,
            counters: counters
          )
          {
            "name" => name,
            "path_sha256" => Digest::SHA256.hexdigest(path),
            "state" => "present".freeze,
            "entries" =>
              entries.sort_by do |entry|
                entry.fetch("path")
              end.freeze
          }.freeze
        end

        def walk_directory(path, relative, depth:, entries:, counters:)
          malformed! if depth > MAX_DEPTH
          before = File.lstat(path)
          malformed! unless safe_directory?(before)
          add_entry!(
            entries,
            {
              "type" => "directory".freeze,
              "path" => relative.dup.freeze,
              "mode" => permission_mode(before)
            }.freeze,
            counters
          )
          children =
            Dir.open(path) do |directory|
              directory.each_child.to_a.sort
            end
          children.each do |name|
            malformed! if name.bytesize > MAX_PATH_BYTES
            child = File.join(path, name)
            child_relative =
              relative == "." ? name : File.join(relative, name)
            malformed! unless safe_relative_path?(child_relative)
            stat = File.lstat(child)
            if stat.directory?
              walk_directory(
                child,
                child_relative,
                depth: depth + 1,
                entries: entries,
                counters: counters
              )
            elsif stat.file?
              capture_file(
                child,
                child_relative,
                stat,
                entries,
                counters
              )
            else
              malformed!
            end
          end
          after = File.lstat(path)
          malformed! unless same_stat?(before, after)
        end

        def capture_file(path, relative, before, entries, counters)
          malformed! unless safe_file?(before) &&
                            before.size <= MAX_FILE_BYTES
          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          digest_value = Digest::SHA256.new
          bytes = 0
          opened = File.open(path, flags)
          opened_before = opened.stat
          malformed! unless same_stat?(before, opened_before)
          while (chunk = opened.read(64 * 1024))
            bytes += chunk.bytesize
            malformed! if bytes > MAX_FILE_BYTES ||
                          counters.fetch(:bytes) + bytes >
                            MAX_TOTAL_BYTES
            digest_value << chunk
          end
          opened_after = opened.stat
          after = File.lstat(path)
          malformed! unless bytes == before.size &&
                            same_stat?(before, opened_after) &&
                            same_stat?(before, after)
          counters[:files] += 1
          counters[:bytes] += bytes
          add_entry!(
            entries,
            {
              "type" => "file".freeze,
              "path" => relative.dup.freeze,
              "mode" => permission_mode(before),
              "size" => bytes,
              "sha256" => digest_value.hexdigest.freeze
            }.freeze,
            counters
          )
        ensure
          opened&.close
        end

        def add_entry!(entries, entry, counters)
          counters[:entries] += 1
          malformed! if counters.fetch(:entries) > MAX_ENTRIES
          entries << entry
        end

        def safe_directory?(stat)
          stat.directory? &&
            !stat.symlink? &&
            stat.uid == Process.euid &&
            (permission_mode(stat) & 0o022).zero?
        end

        def safe_file?(stat)
          stat.file? &&
            !stat.symlink? &&
            stat.nlink == 1 &&
            stat.uid == Process.euid &&
            (permission_mode(stat) & 0o022).zero?
        end

        def permission_mode(stat)
          stat.mode & 0o7777
        end

        def same_stat?(left, right)
          %i[dev ino mode nlink uid gid size mtime ctime].all? do |name|
            left.public_send(name) == right.public_send(name)
          end
        end

        def safe_relative_path?(path)
          path.is_a?(String) &&
            !path.empty? &&
            path.bytesize <= MAX_PATH_BYTES &&
            !path.start_with?(File::SEPARATOR) &&
            !path.include?("\0") &&
            path.split(File::SEPARATOR).none? do |part|
              part.empty? || part == "." || part == ".."
            end
        end

        def snapshot_from_h(value)
          value = immutable_hash(value)
          exact_keys!(value, SNAPSHOT_KEYS)
          malformed! unless
            value.fetch("schema") == SNAPSHOT_SCHEMA &&
              value.fetch("schema_version") == SCHEMA_VERSION &&
              DIGEST.match?(value.fetch("sandbox_root_sha256").to_s) &&
              DIGEST.match?(value.fetch("snapshot_sha256").to_s)
          roots = value.fetch("roots")
          malformed! unless roots.is_a?(Array) &&
                            roots.length.between?(1, MAX_ROOTS)
          names = []
          entry_count = 0
          file_count = 0
          total_bytes = 0
          roots.each do |root|
            exact_keys!(root, SNAPSHOT_ROOT_KEYS)
            name = root.fetch("name")
            state = root.fetch("state")
            entries = root.fetch("entries")
            malformed! unless ROOT_NAME.match?(name.to_s) &&
                              DIGEST.match?(
                                root.fetch("path_sha256").to_s
                              ) &&
                              %w[absent present].include?(state) &&
                              entries.is_a?(Array)
            names << name
            if state == "absent"
              malformed! unless entries.empty?
              next
            end
            malformed! unless !entries.empty? &&
                              entries.length <= MAX_ENTRIES
            paths = entries.map do |entry|
              entry_count += 1
              type = entry.fetch("type")
              keys =
                type == "directory" ?
                  DIRECTORY_ENTRY_KEYS : FILE_ENTRY_KEYS
              exact_keys!(entry, keys)
              malformed! unless %w[directory file].include?(type) &&
                                valid_mode?(entry.fetch("mode")) &&
                                valid_entry_path?(entry.fetch("path"))
              if type == "file"
                size = entry.fetch("size")
                malformed! unless
                  size.is_a?(Integer) &&
                    size.between?(0, MAX_FILE_BYTES) &&
                    DIGEST.match?(entry.fetch("sha256").to_s)
                file_count += 1
                total_bytes += size
              end
              entry.fetch("path")
            end
            malformed! unless paths.fetch(0) == "." &&
                              paths.drop(1) == paths.drop(1).sort &&
                              paths.uniq.length == paths.length
            entry_types = entries.to_h do |entry|
              [ entry.fetch("path"), entry.fetch("type") ]
            end
            entries.drop(1).each do |entry|
              parent = File.dirname(entry.fetch("path"))
              parent = "." if parent == "."
              malformed! unless
                entry_types.fetch(parent, nil) == "directory"
            end
          end
          malformed! unless names == names.sort &&
                            names.uniq.length == names.length &&
                            entry_count <= MAX_ENTRIES &&
                            total_bytes <= MAX_TOTAL_BYTES &&
                            value.fetch("root_count") == roots.length &&
                            value.fetch("entry_count") == entry_count &&
                            value.fetch("file_count") == file_count &&
                            value.fetch("total_bytes") == total_bytes
          body = value.reject { |key, _| key == "snapshot_sha256" }
          malformed! unless
            value.fetch("snapshot_sha256") ==
              digest("qualification-state-snapshot", body)

          Snapshot.new(payload: value).freeze
        rescue KeyError, NoMethodError, TypeError
          malformed!
        end

        def checkpoint_from_h(value)
          value = immutable_hash(value)
          exact_keys!(value, CHECKPOINT_KEYS)
          malformed! unless
            value.fetch("schema") == CHECKPOINT_SCHEMA &&
              value.fetch("schema_version") == SCHEMA_VERSION &&
              CHECKPOINTS.include?(value.fetch("checkpoint")) &&
              DIGEST.match?(value.fetch("state_sha256").to_s) &&
              DIGEST.match?(value.fetch("evidence_sha256").to_s)
          facts = validated_facts(value.fetch("facts"))
          body = value.reject { |key, _| key == "evidence_sha256" }
          malformed! unless facts == value.fetch("facts") &&
                            value.fetch("evidence_sha256") ==
                              digest(
                                "qualification-checkpoint-evidence",
                                body
                              )

          Checkpoint.new(payload: value).freeze
        rescue KeyError, NoMethodError, TypeError
          malformed!
        end

        def validated_snapshot(value)
          payload = value.is_a?(Snapshot) ? value.to_h : value
          snapshot_from_h(payload)
        end

        def validated_checkpoint(value)
          malformed! unless value.is_a?(String) &&
                            CHECKPOINTS.include?(value)

          value.dup.freeze
        end

        def validated_facts(value)
          nodes = { count: 0 }
          facts = immutable_json(
            value,
            depth: 0,
            nodes: nodes
          )
          malformed! unless facts.is_a?(Hash) &&
                            !facts.empty? &&
                            canonical(facts).bytesize <= MAX_FACT_BYTES

          facts
        end

        def immutable_hash(value)
          malformed! unless value.is_a?(Hash)

          immutable_json(
            value,
            depth: 0,
            nodes: {
              count: 0,
              limit: MAX_SNAPSHOT_NODES
            }
          )
        end

        def immutable_json(value, depth:, nodes:)
          malformed! if depth > MAX_FACT_DEPTH
          nodes[:count] += 1
          malformed! if nodes.fetch(:count) >
                        nodes.fetch(:limit, MAX_FACT_NODES)
          case value
          when Hash
            malformed! unless value.keys.all? do |key|
              key.is_a?(String) && FACT_KEY.match?(key)
            end
            value.keys.sort.to_h do |key|
              [
                key.dup.freeze,
                immutable_json(
                  value.fetch(key),
                  depth: depth + 1,
                  nodes: nodes
                )
              ]
            end.freeze
          when Array
            value.map do |child|
              immutable_json(
                child,
                depth: depth + 1,
                nodes: nodes
              )
            end.freeze
          when String
            malformed! unless value.valid_encoding? &&
                              value.bytesize <= MAX_FACT_STRING_BYTES
            value.dup.freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          else
            malformed!
          end
        end

        def exact_keys!(value, keys)
          malformed! unless value.is_a?(Hash) &&
                            value.keys.sort == keys.sort
        end

        def valid_mode?(value)
          value.is_a?(Integer) &&
            value.between?(0, 0o7777) &&
            (value & 0o022).zero?
        end

        def valid_entry_path?(value)
          value == "." || safe_relative_path?(value)
        end

        def digest(domain, value)
          Digest::SHA256.hexdigest(
            "#{domain}\0#{canonical(value)}"
          ).freeze
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def malformed!
          raise Hive::ConfigError, ERROR
        end
      end
    end
  end
end
