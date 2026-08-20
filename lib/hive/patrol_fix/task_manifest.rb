require "json"
require "hive/patrol_fix"
require "hive/atomic_file"

module Hive
  module PatrolFix
    class TaskManifest
      FILENAME = "patrol-fix-manifest.json".freeze
      SCHEMA = "hive-patrol-fix-task-manifest".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = 256 * 1024
      MAX_SOURCES = 64
      MAX_ALIASES = 128
      MAX_ISSUES = 64
      MAX_EVIDENCE = 64
      MAX_AFFECTED_CODE = 256
      MAX_LINEAGE = 64
      MAX_TEXT_BYTES = 16 * 1024
      MAX_SHORT_TEXT_BYTES = 512
      DIGEST = /\A[0-9a-f]{64}\z/
      REVISION = /\A[0-9a-f]{40}\z/
      SLUG = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/
      SOURCE_ENGINES = %w[ordinary_patrol architecture_patrol].freeze
      ALIAS_KINDS = %w[ordinary_finding architecture_thesis canonical_task legacy_issue external_issue].freeze

      class InvalidManifest < Hive::Error; end

      attr_reader :task_folder, :path

      def initialize(task_folder:)
        @task_folder = File.expand_path(task_folder)
        @path = File.join(@task_folder, FILENAME)
      end

      def read
        validate!(JSON.parse(read_bytes))
      rescue JSON::ParserError => e
        invalid!("manifest is malformed JSON: #{e.message}")
      end

      def write!(document)
        normalized = validate!(PatrolFix.deep_copy(document))
        validate_transition!(read, normalized) if File.exist?(path) || File.symlink?(path)
        body = PatrolFix.canonical_json(normalized)
        invalid!("manifest exceeds the size limit") if body.bytesize > MAX_BYTES

        reject_symlink!
        Hive::AtomicFile.write(path, body, mode: 0o600)
        Hive::AtomicFile.fsync_directory(task_folder)
        normalized
      rescue JSON::GeneratorError, ArgumentError => e
        invalid!(e.message)
      end

      private

      def validate!(document)
        hash!(document, "manifest")
        exact_keys!(document, %w[
          schema schema_version task evidence_revision target_revision sources aliases relations
        ], "manifest")
        invalid!("unknown manifest schema") unless document["schema"] == SCHEMA
        invalid!("unknown manifest schema version") unless document["schema_version"] == SCHEMA_VERSION

        validate_task!(document.fetch("task"))
        validate_revision!(document.fetch("evidence_revision"))
        invalid!("task and evidence generations must match") unless
          document.dig("task", "generation") == document.dig("evidence_revision", "generation")
        string!(document.fetch("target_revision"), "target_revision", max: 40, pattern: REVISION)
        array!(document.fetch("sources"), "sources", min: 1, max: MAX_SOURCES)
          .each_with_index { |source, index| validate_source!(source, index) }
        identities = document.fetch("sources").map { |source| [ source["engine"], source["identity"] ] }
        invalid!("source identities must be unique") unless identities.uniq.length == identities.length
        array!(document.fetch("aliases"), "aliases", max: MAX_ALIASES)
          .each_with_index { |entry, index| validate_alias!(entry, index) }
        validate_relations!(document.fetch("relations"))
        PatrolFix.deep_freeze(document)
      rescue KeyError => e
        invalid!("manifest is missing #{e.key.inspect}")
      end

      def validate_task!(task)
        hash!(task, "task")
        exact_keys!(task, %w[slug generation], "task")
        string!(task.fetch("slug"), "task.slug", max: 64, pattern: SLUG)
        positive_integer!(task.fetch("generation"), "task.generation")
      end

      def validate_revision!(revision)
        hash!(revision, "evidence_revision")
        exact_keys!(revision, %w[generation digest], "evidence_revision")
        positive_integer!(revision.fetch("generation"), "evidence_revision.generation")
        string!(revision.fetch("digest"), "evidence_revision.digest", max: 64, pattern: DIGEST)
      end

      def validate_source!(source, index)
        label = "sources[#{index}]"
        hash!(source, label)
        exact_keys!(source, %w[
          engine identity target_revision evidence affected_code reproduction_guidance discovery_run semantic_lineage
        ], label)
        invalid!("#{label}.engine is unknown") unless SOURCE_ENGINES.include?(source["engine"])
        string!(source.fetch("identity"), "#{label}.identity", max: MAX_SHORT_TEXT_BYTES)
        string!(source.fetch("target_revision"), "#{label}.target_revision", max: 40, pattern: REVISION)
        string_array!(source.fetch("evidence"), "#{label}.evidence", min: 1,
                      max: MAX_EVIDENCE, item_max: MAX_TEXT_BYTES)
        paths = string_array!(source.fetch("affected_code"), "#{label}.affected_code", min: 1,
                              max: MAX_AFFECTED_CODE, item_max: 1_024)
        paths.each { |value| safe_relative_path!(value, "#{label}.affected_code") }
        string!(source.fetch("reproduction_guidance"), "#{label}.reproduction_guidance",
                max: MAX_TEXT_BYTES)
        string!(source.fetch("discovery_run"), "#{label}.discovery_run", max: MAX_SHORT_TEXT_BYTES)
        string_array!(source.fetch("semantic_lineage"), "#{label}.semantic_lineage", min: 1,
                      max: MAX_LINEAGE, item_max: MAX_SHORT_TEXT_BYTES)
      end

      def validate_alias!(entry, index)
        label = "aliases[#{index}]"
        hash!(entry, label)
        exact_keys!(entry, %w[kind value], label)
        invalid!("#{label}.kind is unknown") unless ALIAS_KINDS.include?(entry["kind"])
        string!(entry.fetch("value"), "#{label}.value", max: 2_048)
      end

      def validate_relations!(relations)
        hash!(relations, "relations")
        exact_keys!(relations, %w[successor issues], "relations")
        successor = relations.fetch("successor")
        if successor
          hash!(successor, "relations.successor")
          exact_keys!(successor, %w[project slug], "relations.successor")
          string!(successor.fetch("project"), "relations.successor.project", max: 128)
          string!(successor.fetch("slug"), "relations.successor.slug", max: 64, pattern: SLUG)
        end
        array!(relations.fetch("issues"), "relations.issues", max: MAX_ISSUES)
          .each_with_index { |issue, index| validate_issue!(issue, index) }
      end

      def validate_issue!(issue, index)
        label = "relations.issues[#{index}]"
        hash!(issue, label)
        exact_keys!(issue, %w[url number], label)
        string!(issue.fetch("url"), "#{label}.url", max: 2_048)
        positive_integer!(issue.fetch("number"), "#{label}.number")
      end

      def validate_transition!(current, candidate)
        current_generation = current.dig("evidence_revision", "generation")
        next_generation = candidate.dig("evidence_revision", "generation")
        current_digest = current.dig("evidence_revision", "digest")
        next_digest = candidate.dig("evidence_revision", "digest")
        invalid!("task slug is immutable") unless current.dig("task", "slug") == candidate.dig("task", "slug")
        invalid!("target revision is immutable within a task generation") if
          next_generation == current_generation && current["target_revision"] != candidate["target_revision"]
        if next_generation == current_generation
          invalid!("evidence digest changes require the next generation") unless current_digest == next_digest
          invalid!("source provenance is append-only within an evidence generation") unless
            candidate.fetch("sources").first(current.fetch("sources").length) == current.fetch("sources")
        elsif next_generation == current_generation + 1
          invalid!("the next generation requires materially changed evidence") if current_digest == next_digest
        else
          invalid!("manifest generation must remain current or advance by one")
        end
      end

      def read_bytes
        reject_symlink!
        stat = File.lstat(path)
        invalid!("manifest must be a regular file") unless stat.file?
        invalid!("manifest exceeds the size limit") if stat.size > MAX_BYTES

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          bytes = file.read(MAX_BYTES + 1).to_s
          invalid!("manifest exceeds the size limit") if bytes.bytesize > MAX_BYTES
          bytes
        end
      rescue Errno::ELOOP
        invalid!("manifest must not be a symlink")
      rescue Errno::ENOENT
        invalid!("manifest is missing")
      rescue SystemCallError, IOError => e
        invalid!("manifest is unreadable: #{e.message}")
      end

      def reject_symlink!
        return unless File.symlink?(path)

        invalid!("manifest must not be a symlink")
      end

      def exact_keys!(value, keys, label)
        return if value.keys.sort == keys.sort

        invalid!("#{label} fields must be exactly #{keys.join(', ')}")
      end

      def hash!(value, label)
        invalid!("#{label} must be an object") unless value.is_a?(Hash)
        value
      end

      def array!(value, label, min: 0, max:)
        invalid!("#{label} must be an array") unless value.is_a?(Array)
        invalid!("#{label} must contain at least #{min} entries") if value.length < min
        invalid!("#{label} exceeds #{max} entries") if value.length > max
        value
      end

      def string_array!(value, label, min: 0, max:, item_max:)
        array!(value, label, min: min, max: max).each_with_index do |entry, index|
          string!(entry, "#{label}[#{index}]", max: item_max)
        end
      end

      def string!(value, label, max:, pattern: nil)
        invalid!("#{label} must be a non-empty string") unless value.is_a?(String) && !value.empty?
        invalid!("#{label} exceeds #{max} bytes") if value.bytesize > max
        invalid!("#{label} contains invalid control characters") if value.match?(/[\u0000-\u001f\u007f]/)
        invalid!("#{label} has an invalid format") if pattern && !value.match?(pattern)
        value
      end

      def positive_integer!(value, label)
        invalid!("#{label} must be a positive integer") unless value.is_a?(Integer) && value.positive?
      end

      def safe_relative_path!(value, label)
        invalid!("#{label} must contain relative repository paths") if
          value.start_with?("/") || value.include?("\\") || value.split("/").include?("..")
      end

      def invalid!(message)
        raise InvalidManifest, message.to_s[0, 512]
      end
    end
  end
end
