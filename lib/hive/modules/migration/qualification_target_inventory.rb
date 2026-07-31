require "digest"
require "json"
require "hive/errors"
require "hive/modules/migration/bounded_directory_entries"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Bounded, host-side snapshot of one materialized candidate target.
      # Entries contain only relative paths and content metadata so the same
      # bytes produce the same identity under different host roots.
      class QualificationTargetInventory
        MAX_ENTRIES = 8_192
        MAX_DEPTH = 64
        MAX_FILE_BYTES = 128 * 1024 * 1024
        MAX_TOTAL_BYTES = 1024 * 1024 * 1024
        MAX_PATH_BYTES = 4_096
        DOMAIN = "hive-qualification-target-inventory-v1".freeze

        Snapshot = Data.define(
          :digest, :entry_count, :file_count, :total_bytes,
          :entries
        )

        def initialize(
          max_entries: MAX_ENTRIES,
          max_depth: MAX_DEPTH,
          max_file_bytes: MAX_FILE_BYTES,
          max_total_bytes: MAX_TOTAL_BYTES,
          max_path_bytes: MAX_PATH_BYTES
        )
          @max_entries = positive_integer(max_entries)
          @max_depth = positive_integer(max_depth)
          @max_file_bytes = positive_integer(max_file_bytes)
          @max_total_bytes = positive_integer(max_total_bytes)
          @max_path_bytes = positive_integer(max_path_bytes)
        end

        def call(root)
          root = validate_root(root)
          entries = {}
          totals = { files: 0, bytes: 0 }
          walk(
            root,
            "",
            entries,
            totals,
            depth: 0
          )
          canonical_entries =
            entries.keys.sort.map do |path|
              entries.fetch(path)
            end.freeze
          identity = Hive::WorkflowPackage::CanonicalJSON.generate(
            "domain" => DOMAIN,
            "entries" => canonical_entries
          )
          Snapshot.new(
            digest: Digest::SHA256.hexdigest(identity).freeze,
            entry_count: canonical_entries.length,
            file_count: totals.fetch(:files),
            total_bytes: totals.fetch(:bytes),
            entries: canonical_entries
          ).freeze
        rescue Hive::ConfigError
          raise
        rescue SystemCallError, IOError, ArgumentError, TypeError
          malformed!
        end

        private

        def walk(root, relative, entries, totals, depth:)
          malformed! if depth > @max_depth
          absolute =
            relative.empty? ? root : File.join(root, relative)
          stat = File.lstat(absolute)
          validate_common!(stat)
          unless relative.empty?
            validate_relative!(relative, depth)
            malformed! if entries.length >= @max_entries
          end

          if stat.directory?
            entries[relative] = {
              "path" => relative,
              "type" => "directory",
              "mode" => stat.mode & 0o777
            }.freeze unless relative.empty?
            children = bounded_names(
              absolute,
              limit: @max_entries - entries.length
            )
            children.each do |name|
              validate_name!(name)
              child =
                relative.empty? ? name : "#{relative}/#{name}"
              walk(
                root,
                child,
                entries,
                totals,
                depth: depth + 1
              )
            end
            return
          end

          malformed! unless stat.file? && stat.nlink == 1
          size = Integer(stat.size)
          malformed! if
            size.negative? || size > @max_file_bytes
          totals[:files] += 1
          totals[:bytes] += size
          malformed! if totals.fetch(:bytes) > @max_total_bytes
          bytes = read_file(absolute, stat)
          entries[relative] = {
            "path" => relative,
            "type" => "file",
            "mode" => stat.mode & 0o777,
            "size" => size,
            "sha256" => Digest::SHA256.hexdigest(bytes)
          }.freeze
        end

        def validate_root(value)
          root = value.to_s
          malformed! unless
            !root.empty? &&
              !root.include?("\0") &&
              root == File.expand_path(root)
          stat = File.lstat(root)
          malformed! unless
            stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o022).zero? &&
              File.realpath(root) == root
          root.freeze
        end

        def validate_common!(stat)
          malformed! unless
            !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o022).zero?
        end

        def validate_relative!(value, depth)
          malformed! unless
            !value.empty? &&
              value.bytesize <= @max_path_bytes &&
              depth.between?(1, @max_depth) &&
              value.dup.force_encoding(Encoding::UTF_8)
                .valid_encoding?
        end

        def validate_name!(value)
          malformed! unless
            !value.empty? &&
              value != "." &&
              value != ".." &&
              !value.include?("/") &&
              !value.include?("\\") &&
              !value.include?("\0")
        end

        def bounded_names(path, limit:)
          BoundedDirectoryEntries.names(path, limit: limit)
        rescue Hive::ConfigError
          malformed!
        end

        def read_file(path, before)
          flags = File::RDONLY
          flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
          opened = File.open(path, flags)
          malformed! unless same_file?(before, opened.stat)
          bytes = opened.read(@max_file_bytes + 1)
          bytes = "".b if bytes.nil? && before.size.zero?
          malformed! unless
            bytes &&
              bytes.bytesize == before.size &&
              same_file?(before, opened.stat) &&
              same_file?(before, File.lstat(path))

          bytes.freeze
        ensure
          opened&.close
        end

        def same_file?(left, right)
          %i[
            dev ino mode nlink uid gid size mtime ctime
          ].all? do |field|
            left.public_send(field) == right.public_send(field)
          end
        end

        def positive_integer(value)
          integer = Integer(value)
          malformed! unless integer.positive?
          integer
        rescue ArgumentError, TypeError
          malformed!
        end

        def malformed!
          raise Hive::ConfigError,
                "patrol qualification target inventory is unsafe"
        end
      end
    end
  end
end
