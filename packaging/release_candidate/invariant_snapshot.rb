# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require_relative "paths"

module HiveReleaseCandidate
  class InvariantSnapshot
    COMMON_SECTIONS = %w[
      channel_sidecars configuration default_workflow dependencies
      dispatch_receipts durable_attempts global_registry install_identity
      managed_web_data markers project_registry service_definitions status_json
      doctor_json tasks
    ].freeze
    HISTORICAL_SECTIONS = %w[builtin_runtime legacy_descriptor legacy_instructions].freeze
    MAX_CAPTURE_BYTES = 1_048_576
    SEMANTIC_JSON_SECTIONS = %w[doctor_json status_json].freeze
    VOLATILE_JSON_KEYS = %w[
      binary binary_path elapsed_ms executable finished_at generated_at
      hive_version observed_at pid process_start_time schema_version started_at
      timestamp updated_at version
    ].freeze

    class << self
      def build(row_id:, sections:)
        normalized = normalize_hash(sections, "invariant sections")
        required = COMMON_SECTIONS + (row_id == "legacy-bench-v041" ? HISTORICAL_SECTIONS : [])
        missing = required - normalized.keys
        extra = normalized.keys - required
        raise Error, "invariant snapshot missing sections: #{missing.join(', ')}" unless missing.empty?
        raise Error, "invariant snapshot has unknown sections: #{extra.join(', ')}" unless extra.empty?

        SEMANTIC_JSON_SECTIONS.each do |name|
          normalized[name] = semantic_json(normalized.fetch(name))
        end
        canonical = deep_sort(normalized)
        {
          "schema" => "hive-release-candidate-invariant-snapshot",
          "schema_version" => SCHEMA_VERSION,
          "row_id" => row_id,
          "sections" => canonical,
          "sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical))
        }
      end

      def compare(before:, after:, allowed_migrations: [])
        validate_snapshot!(before)
        validate_snapshot!(after)
        unless before.fetch("row_id") == after.fetch("row_id")
          raise Error, "cannot compare invariant snapshots from different baseline rows"
        end
        allowed = allowed_migrations.map { |path| validate_pointer!(path) }.uniq.sort
        changes = diff(before.fetch("sections"), after.fetch("sections"))
        permitted, unexpected = changes.partition do |change|
          allowed.any? do |prefix|
            change.fetch("path") == prefix || change.fetch("path").start_with?("#{prefix}/")
          end
        end
        {
          "passed" => unexpected.empty?,
          "allowed_migrations" => allowed,
          "allowed" => permitted,
          "unexpected" => unexpected
        }
      end

      def capture_tree(root:, sections:)
        root = safe_root!(root)
        unless sections.is_a?(Hash) && !sections.empty?
          raise UsageError, "capture sections must be a non-empty hash"
        end
        captured = sections.to_h do |name, relative|
          name = name.to_s
          path = confined_path!(root, relative)
          [ name, capture_path(path, root) ]
        end
        captured
      end

      private

      def validate_snapshot!(snapshot)
        unless snapshot.is_a?(Hash) &&
               snapshot["schema"] == "hive-release-candidate-invariant-snapshot" &&
               snapshot["schema_version"] == SCHEMA_VERSION &&
               /\A[0-9a-f]{64}\z/.match?(snapshot["sha256"].to_s)
          raise Error, "invalid invariant snapshot"
        end
        expected = Digest::SHA256.hexdigest(JSON.generate(deep_sort(snapshot.fetch("sections"))))
        raise Error, "invariant snapshot digest mismatch" unless expected == snapshot.fetch("sha256")
      end

      def validate_pointer!(value)
        pointer = value.to_s
        unless pointer.start_with?("/") && !pointer.include?("\0") && !pointer.include?("//")
          raise UsageError, "allowed migration must be an exact JSON pointer"
        end
        pointer
      end

      def diff(before, after, pointer = "")
        if before.is_a?(Hash) && after.is_a?(Hash)
          return (before.keys | after.keys).sort.flat_map do |key|
            child = "#{pointer}/#{escape_pointer(key)}"
            if !before.key?(key)
              [ change(child, nil, after.fetch(key)) ]
            elsif !after.key?(key)
              [ change(child, before.fetch(key), nil) ]
            else
              diff(before.fetch(key), after.fetch(key), child)
            end
          end
        end
        if before.is_a?(Array) && after.is_a?(Array)
          return (0...[ before.length, after.length ].max).flat_map do |index|
            child = "#{pointer}/#{index}"
            if index >= before.length
              [ change(child, nil, after.fetch(index)) ]
            elsif index >= after.length
              [ change(child, before.fetch(index), nil) ]
            else
              diff(before.fetch(index), after.fetch(index), child)
            end
          end
        end
        before == after ? [] : [ change(pointer, before, after) ]
      end

      def change(path, before, after)
        { "path" => path, "before" => before, "after" => after }
      end

      def escape_pointer(value)
        value.to_s.gsub("~", "~0").gsub("/", "~1")
      end

      def normalize_hash(value, label)
        raise Error, "#{label} must be an object" unless value.is_a?(Hash)

        value.to_h do |key, child|
          name = key.to_s
          raise Error, "#{label} contains an empty or unsafe key" if name.empty? || name.include?("\0")
          [ name, normalize(child) ]
        end
      end

      def normalize(value)
        case value
        when Hash then normalize_hash(value, "invariant value")
        when Array then value.map { |child| normalize(child) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass then value
        else
          raise Error, "invariant value has unsupported type #{value.class}"
        end
      end

      def deep_sort(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [ key, deep_sort(value.fetch(key)) ] }
        when Array then value.map { |child| deep_sort(child) }
        else value
        end
      end

      def semantic_json(value)
        case value
        when Hash
          value.keys.sort.each_with_object({}) do |key, output|
            next if VOLATILE_JSON_KEYS.include?(key)
            output[key] = semantic_json(value.fetch(key))
          end
        when Array
          value.map { |child| semantic_json(child) }
            .sort_by { |child| JSON.generate(deep_sort(child)) }
        else
          value
        end
      end

      def safe_root!(value)
        root = File.expand_path(value)
        stat = File.lstat(root)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise Error, "invariant capture root must be an owned directory"
        end
        root
      rescue Errno::ENOENT, Errno::EACCES
        raise Error, "invariant capture root must be an owned directory"
      end

      def confined_path!(root, value)
        relative = Pathname.new(value.to_s)
        clean = relative.cleanpath.to_s
        if relative.absolute? || clean == ".." || clean.start_with?("../") || value.to_s.include?("\\")
          raise Error, "invariant capture path escapes its root"
        end
        File.join(root, clean)
      end

      def capture_path(path, root)
        stat = File.lstat(path)
        raise Error, "invariant capture refuses symlink: #{path}" if stat.symlink?
        if stat.file?
          raise Error, "invariant capture file exceeds #{MAX_CAPTURE_BYTES} bytes" if stat.size > MAX_CAPTURE_BYTES
          return {
            "kind" => "file", "size" => stat.size,
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        end
        raise Error, "invariant capture path is not a regular file or directory" unless stat.directory?

        entries = Dir.children(path).sort.to_h do |name|
          child = File.join(path, name)
          relative = Pathname.new(child).relative_path_from(Pathname.new(root)).to_s
          [ name, capture_path(confined_path!(root, relative), root) ]
        end
        { "kind" => "directory", "entries" => entries }
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Error, "cannot capture invariant path #{path}: #{e.message}"
      end
    end
  end
end
