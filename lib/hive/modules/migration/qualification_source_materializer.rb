require "digest"
require "fileutils"
require "rubygems/package"
require "stringio"
require "zlib"
require "hive/errors"
require "hive/managed_directory"

module Hive
  module Modules
    module Migration
      # Runtime-shipped safe materializer for descriptor-bound source archives.
      # It accepts only plain files/directories and publishes nothing until the
      # complete archive has survived path, type, and expansion bounds.
      class QualificationSourceMaterializer
        MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
        MAX_ENTRIES = 4_096
        MAX_DEPTH = 32
        MAX_PATH_BYTES = 4_096
        MAX_FILE_BYTES = 64 * 1024 * 1024
        MAX_TOTAL_BYTES = 512 * 1024 * 1024
        MAX_RATIO = 200

        Result = Data.define(
          :root, :tree_sha256, :file_count, :total_bytes
        )

        def initialize(
          max_archive_bytes: MAX_ARCHIVE_BYTES,
          max_entries: MAX_ENTRIES,
          max_depth: MAX_DEPTH,
          max_path_bytes: MAX_PATH_BYTES,
          max_file_bytes: MAX_FILE_BYTES,
          max_total_bytes: MAX_TOTAL_BYTES,
          max_ratio: MAX_RATIO
        )
          @max_archive_bytes =
            positive_integer(max_archive_bytes)
          @max_entries = positive_integer(max_entries)
          @max_depth = positive_integer(max_depth)
          @max_path_bytes = positive_integer(max_path_bytes)
          @max_file_bytes = positive_integer(max_file_bytes)
          @max_total_bytes = positive_integer(max_total_bytes)
          @max_ratio = positive_integer(max_ratio)
        end

        def materialize(bytes, destination:, executable_ref:)
          archive = validate_archive(bytes)
          root = prepare_destination(destination)
          executable = normalized_name(
            executable_ref,
            directory: false
          )
          directory = Hive::ManagedDirectory.new(
            root: root,
            anchor: File.dirname(root),
            label: "patrol qualification source"
          )
          directory.prepare!
          types = {}
          explicit = {}
          records = {}
          total = 0
          entries = 0

          Zlib::GzipReader.wrap(StringIO.new(archive)) do |gzip|
            Gem::Package::TarReader.new(gzip) do |tar|
              tar.each do |entry|
                entries += 1
                malformed! if entries > @max_entries
                kind =
                  if entry.directory?
                    :directory
                  elsif entry.file?
                    :file
                  else
                    malformed!
                  end
                name = normalized_name(
                  entry.full_name,
                  directory: kind == :directory
                )
                malformed! if explicit.key?(name)
                explicit[name] = kind
                validate_structure!(types, name, kind)
                if kind == :directory
                  directory.ensure_directory(name)
                  types[name] = :directory
                  next
                end

                size = Integer(entry.header.size)
                malformed! if
                  size.negative? || size > @max_file_bytes
                total += size
                malformed! if
                  total > @max_total_bytes ||
                    total > archive.bytesize * @max_ratio
                content = entry.read
                malformed! unless content.bytesize == size
                ensure_parents!(directory, types, name)
                mode = name == executable ? 0o700 : 0o600
                directory.atomic_write(
                  name,
                  content,
                  mode: mode,
                  expected_absent: true
                )
                types[name] = :file
                records[name] = {
                  mode: mode,
                  size: size,
                  sha256: Digest::SHA256.hexdigest(content)
                }.freeze
              end
            end
          end
          malformed! unless
            records.key?(executable) &&
              types.fetch(executable) == :file
          result = Result.new(
            root: root.freeze,
            tree_sha256: tree_digest(records),
            file_count: records.length,
            total_bytes: total
          ).freeze
          result
        rescue Hive::ConfigError
          cleanup_destination(destination)
          raise
        rescue Gem::Package::TarInvalidError, Zlib::Error,
               EOFError, IOError, SystemCallError,
               ArgumentError, TypeError
          cleanup_destination(destination)
          malformed!
        end

        private

        def validate_archive(value)
          malformed! unless
            value.is_a?(String) &&
              !value.empty? &&
              value.bytesize <= @max_archive_bytes
          value.b
        end

        def prepare_destination(value)
          path = value.to_s
          expanded = File.expand_path(path)
          malformed! unless
            !path.empty? &&
              !path.include?("\0") &&
              path == expanded &&
              !File.exist?(path) &&
              !File.symlink?(path)
          parent = File.dirname(path)
          stat = File.lstat(parent)
          malformed! unless
            stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o077).zero? &&
              File.realpath(parent) == parent
          Dir.mkdir(path, 0o700)
          created = File.lstat(path)
          malformed! unless
            created.directory? &&
              !created.symlink? &&
              created.uid == Process.euid &&
              (created.mode & 0o777) == 0o700
          path.freeze
        end

        def normalized_name(value, directory:)
          text = value.to_s
          text = text.delete_suffix("/") if directory
          malformed! unless
            !text.empty? &&
              text.bytesize <= @max_path_bytes &&
              text.dup.force_encoding(Encoding::UTF_8)
                .valid_encoding? &&
              !text.start_with?("/") &&
              !text.include?("\\") &&
              !text.include?("\0")
          parts = text.split("/", -1)
          malformed! unless
            parts.length <= @max_depth &&
              parts.none? do |part|
                part.empty? || part == "." || part == ".."
              end
          text.freeze
        end

        def validate_structure!(types, name, kind)
          parts = name.split("/")
          prefixes =
            (1...parts.length).map do |length|
              parts.first(length).join("/")
            end
          malformed! if prefixes.any? do |prefix|
            types[prefix] == :file
          end
          malformed! if
            kind == :file &&
              types.keys.any? do |existing|
                existing.start_with?("#{name}/")
              end
          existing = types[name]
          malformed! if existing && existing != kind
        end

        def ensure_parents!(directory, types, name)
          parts = name.split("/")
          (1...parts.length).each do |length|
            parent = parts.first(length).join("/")
            directory.ensure_directory(parent)
            types[parent] ||= :directory
          end
        end

        def tree_digest(records)
          digest = Digest::SHA256.new
          digest << "hive-qualification-source-tree-v1\0"
          records.keys.sort.each do |name|
            record = records.fetch(name)
            digest << name << "\0"
            digest << record.fetch(:mode).to_s(8) << "\0"
            digest << record.fetch(:size).to_s << "\0"
            digest << record.fetch(:sha256) << "\0"
          end
          digest.hexdigest.freeze
        end

        def cleanup_destination(value)
          path = value.to_s
          return if path.empty? ||
                    path == File::SEPARATOR ||
                    !File.exist?(path) &&
                      !File.symlink?(path)

          FileUtils.remove_entry_secure(path, true)
        rescue SystemCallError, ArgumentError
          nil
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
                "patrol qualification source archive is unsafe"
        end
      end
    end
  end
end
