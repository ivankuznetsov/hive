require "json"
require "fileutils"
require "time"
require "hive/atomic_file"
require "hive/refactor_patrol/semantic_descriptor"
require "hive/refactor_patrol/semantic_family"

module Hive
  module RefactorPatrol
    module FamilyStoreRecords
      FAMILY_KEYS = %w[
        schema schema_version family_id descriptor occurrences created_at updated_at
      ].freeze
      OCCURRENCE_KEYS = %w[fingerprint job_id thesis_id source].freeze
      SOURCE_KEYS = %w[repository url number merge_sha].freeze
      ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/
      DETERMINISTIC_ID_PATTERN = /\Aaf1-[0-9a-f]{64}\z/

      private

      def records
        return [] unless Dir.exist?(@root)

        Dir.glob(File.join(@root, "*.json")).sort.map { |path| read_record(path) }
      rescue SystemCallError, IOError => e
        raise FamilyStore::CorruptRecord.new("cannot enumerate architecture family records (#{e.message})", path: @root)
      end

      def read_record(path)
        data = JSON.parse(File.binread(path))
        validate_record!(data, path)
      rescue JSON::ParserError, EncodingError => e
        raise FamilyStore::CorruptRecord.new("architecture family record is not valid JSON (#{e.message})", path: path)
      rescue SystemCallError, IOError => e
        raise FamilyStore::CorruptRecord.new("cannot read architecture family record (#{e.message})", path: path)
      end

      def validate_record!(data, path)
        corrupt!("architecture family record must be an object", path) unless data.is_a?(Hash)
        unknown = data.keys - FAMILY_KEYS
        corrupt!("architecture family record has unknown keys #{unknown.sort.inspect}", path) unless unknown.empty?
        missing = FAMILY_KEYS - data.keys
        corrupt!("architecture family record is missing #{missing.sort.inspect}", path) unless missing.empty?
        corrupt!("architecture family schema is invalid", path) unless data["schema"] == FamilyStore::SCHEMA
        version = data["schema_version"]
        unless version == FamilyStore::SCHEMA_VERSION
          error = version.is_a?(Integer) && version > FamilyStore::SCHEMA_VERSION ? FamilyStore::UnsupportedVersion : FamilyStore::CorruptRecord
          raise error.new("unsupported architecture family schema version #{version.inspect}", path: path)
        end

        validate_identity!(data, path)
        occurrences = data["occurrences"]
        corrupt!("architecture family occurrences must be an array", path) unless occurrences.is_a?(Array)
        normalized = occurrences.map { |item| validate_occurrence!(item, data.dig("descriptor", "repository"), path) }
        inconsistent!("architecture family contains duplicate occurrences", path) unless normalized.uniq.size == normalized.size
        validate_timestamp!(data["created_at"], "created_at", path)
        validate_timestamp!(data["updated_at"], "updated_at", path)
        inconsistent!("architecture family updated_at predates created_at", path) if Time.iso8601(data["updated_at"]) < Time.iso8601(data["created_at"])
        data
      end

      def validate_identity!(data, path)
        family_id = data["family_id"]
        inconsistent!("architecture family id is unsafe", path) unless family_id.is_a?(String) && family_id.match?(ID_PATTERN)
        filename_id = File.basename(path, ".json")
        inconsistent!("architecture family id conflicts with its filename", path) unless filename_id == family_id
        normalized = SemanticFamily.descriptor(**symbolized_descriptor(data["descriptor"]))
        inconsistent!("architecture family descriptor is not canonical", path) unless normalized == data["descriptor"]
        if family_id.match?(DETERMINISTIC_ID_PATTERN) && SemanticFamily.id_for(normalized) != family_id
          inconsistent!("architecture family descriptor conflicts with its deterministic id", path)
        end
      rescue ArgumentError, KeyError => e
        corrupt!("architecture family descriptor is invalid (#{e.message})", path)
      end

      def validate_occurrence!(item, repository, path)
        corrupt!("architecture family occurrence must be an object", path) unless item.is_a?(Hash)
        unknown = item.keys - OCCURRENCE_KEYS
        corrupt!("architecture family occurrence has unknown keys #{unknown.sort.inspect}", path) unless unknown.empty?
        missing = OCCURRENCE_KEYS - item.keys
        corrupt!("architecture family occurrence is missing #{missing.sort.inspect}", path) unless missing.empty?
        %w[fingerprint job_id thesis_id].each do |key|
          value = item[key]
          corrupt!("architecture family occurrence #{key} must be non-empty", path) unless value.is_a?(String) && !value.strip.empty?
        end
        normalized_source = normalize_source(item["source"], repository)
        inconsistent!("architecture family occurrence source is not canonical", path) unless normalized_source == item["source"]
        item
      rescue ArgumentError => e
        corrupt!("architecture family occurrence source is invalid (#{e.message})", path)
      end

      def normalize_source(source, repository)
        raise ArgumentError, "source must be an object" unless source.is_a?(Hash)

        values = source.transform_keys(&:to_s)
        supplied_repository = values["repository"].to_s.strip.downcase
        expected_repository = repository.to_s.strip.downcase
        unless expected_repository.match?(/\A[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\z/)
          raise ArgumentError, "repository must be an owner/name identity"
        end
        if !supplied_repository.empty? && supplied_repository != expected_repository
          raise ArgumentError, "source repository conflicts with repository"
        end

        normalized = { "repository" => expected_repository }
        %w[url merge_sha].each do |key|
          value = values[key]
          normalized[key] = value.strip if value.is_a?(String) && !value.strip.empty?
        end
        number = values["number"]
        normalized["number"] = number if number.is_a?(Integer) && number.positive?
        normalized.slice(*SOURCE_KEYS)
      end

      def symbolized_descriptor(value)
        raise ArgumentError, "descriptor must be an object" unless value.is_a?(Hash)

        value.to_h { |key, item| [ key.to_sym, item ] }
      end

      def validate_timestamp!(value, label, path)
        raise ArgumentError unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        corrupt!("architecture family #{label} must be an ISO-8601 timestamp", path)
      end

      def build_record(family_id, descriptor, occurrence)
        timestamp = @clock.call.utc.iso8601
        {
          "schema" => FamilyStore::SCHEMA,
          "schema_version" => FamilyStore::SCHEMA_VERSION,
          "family_id" => family_id,
          "descriptor" => descriptor,
          "occurrences" => [ occurrence ],
          "created_at" => timestamp,
          "updated_at" => timestamp
        }
      end

      def with_occurrence(record, occurrence)
        return [ record, false ] if record.fetch("occurrences").include?(occurrence)

        replacement = JSON.parse(JSON.generate(record))
        replacement.fetch("occurrences") << occurrence
        replacement["occurrences"].sort_by! { |item| [ item["fingerprint"], item["job_id"], item["thesis_id"], JSON.generate(item["source"]) ] }
        replacement["updated_at"] = @clock.call.utc.iso8601
        [ replacement, true ]
      end

      def persist!(record)
        path = File.join(@root, "#{record.fetch("family_id")}.json")
        validate_record!(record, path)
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(record)}\n", mode: 0o600)
        fsync_directory(@root)
      end

      def fsync_directory(path)
        File.open(path, File::RDONLY) { |directory| directory.fsync }
      rescue Errno::EINVAL, Errno::ENOTSUP, Errno::EBADF
        nil
      end

      def corrupt!(message, path)
        raise FamilyStore::CorruptRecord.new(message, path: path)
      end

      def inconsistent!(message, path)
        raise FamilyStore::InconsistentRecord.new(message, path: path)
      end
    end

    # Repository-global durable family resolution. One lock protects the full
    # read/resolve/append transition, while each JSON record is atomically
    # renamed and directory-fsynced before the lock is released.
    class FamilyStore
      include FamilyStoreRecords

      SCHEMA = "hive-refactor-patrol-family".freeze
      SCHEMA_VERSION = 1

      class Error < StandardError
        attr_reader :path

        def initialize(message, path: nil)
          @path = path
          super(path ? "#{message}: #{path}" : message)
        end
      end

      class CorruptRecord < Error; end
      class UnsupportedVersion < Error; end
      class InconsistentRecord < Error; end

      Outcome = Struct.new(
        :resolution, :record, :created, :occurrence_added, :persisted,
        :would_create, :would_append, :dry_run,
        keyword_init: true
      ) do
        def status = resolution.status
        def family_id = resolution.family_id
        def descriptor = resolution.descriptor
        def matched_family_ids = resolution.matched_family_ids
        def reason = resolution.reason
        def matched? = resolution.matched?
        def ambiguous? = resolution.ambiguous?
        def new_family? = resolution.new_family?
      end

      attr_reader :project_root, :root

      def initialize(project_root, clock: -> { Time.now })
        @project_root = File.expand_path(project_root)
        @root = File.join(@project_root, ".hive-state", "refactor_patrol", "v2", "families")
        @clock = clock
      end

      def resolve(thesis:, repository:, job_id:, source:, hinted_family_id: nil, dry_run: false)
        occurrence = occurrence_for(thesis, repository, job_id, source)
        descriptor = SemanticDescriptor.call(thesis: thesis, source: occurrence.fetch("source"))
        return resolve_locked(thesis, descriptor, occurrence, hinted_family_id, dry_run: true) if dry_run

        ensure_root!
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          resolve_locked(thesis, descriptor, occurrence, hinted_family_id, dry_run: false)
        end
      end

      private

      def resolve_locked(thesis, descriptor, occurrence, hint, dry_run:)
        current = records
        resolution = resolve_semantic(descriptor, current, occurrence, hint)
        return outcome(resolution, nil, persisted: false, dry_run: dry_run) if resolution.ambiguous?

        existing = current.find { |record| record.fetch("family_id") == resolution.family_id }
        if existing
          replacement, added = with_occurrence(existing, occurrence)
          persist!(replacement) if added && !dry_run
          return outcome(
            resolution, replacement, occurrence_added: added,
            persisted: !dry_run, would_append: added, dry_run: dry_run
          )
        end

        record = build_record(resolution.family_id, resolution.descriptor, occurrence)
        persist!(record) unless dry_run
        outcome(
          resolution, record, created: !dry_run, occurrence_added: !dry_run,
          persisted: !dry_run, would_create: true, would_append: true, dry_run: dry_run
        )
      end

      def resolve_semantic(descriptor, current, occurrence, hint)
        aliases = occurrence_aliases(occurrence)
        matched = current.select { |record| (record_aliases(record) & aliases).any? }
        return alias_resolution(matched, descriptor) unless matched.empty?

        SemanticFamily.resolve(
          descriptor: descriptor,
          families: current.map { |record| semantic_record(record) },
          occurrence_fingerprint: aliases.fetch(0),
          hinted_family_id: hint
        )
      end

      def alias_resolution(matches, descriptor)
        ids = matches.map { |record| record.fetch("family_id") }.uniq.sort
        if ids.size > 1
          return SemanticFamily::Result.new(
            status: "family_ambiguous", family_id: nil, descriptor: descriptor,
            matched_family_ids: ids.freeze, reason: "conflicting_occurrence_alias"
          ).freeze
        end

        record = matches.first
        SemanticFamily::Result.new(
          status: "matched", family_id: record.fetch("family_id"),
          descriptor: record.fetch("descriptor"), matched_family_ids: ids.freeze,
          reason: "occurrence_alias"
        ).freeze
      end

      def semantic_record(record)
        SemanticFamily.family(
          family_id: record.fetch("family_id"),
          descriptor: record.fetch("descriptor"),
          occurrence_fingerprints: record_aliases(record)
        )
      end

      def occurrence_aliases(occurrence)
        aliases = [ alias_token("fingerprint", occurrence.fetch("fingerprint")) ]
        aliases << alias_token("job_thesis", occurrence.fetch("job_id"), occurrence.fetch("thesis_id"))
        source = occurrence.fetch("source")
        aliases << alias_token("source_thesis", source_identity(source), occurrence.fetch("thesis_id")) if source_identity(source)
        aliases
      end

      def record_aliases(record)
        record.fetch("occurrences").flat_map { |occurrence| occurrence_aliases(occurrence) }.uniq.sort
      end

      def source_identity(source)
        identity = source.reject { |key, _| key == "repository" }
        JSON.generate(source) unless identity.empty?
      end

      def alias_token(kind, *parts)
        JSON.generate([ kind, *parts ])
      end

      def occurrence_for(thesis, repository, job_id, source)
        fingerprint = thesis_value(thesis, "fingerprint")
        thesis_id = thesis_value(thesis, "id")
        [ [ fingerprint, "fingerprint" ], [ thesis_id, "thesis id" ], [ job_id, "job id" ] ].each do |value, label|
          raise ArgumentError, "#{label} must be non-empty" if value.to_s.strip.empty?
        end
        {
          "fingerprint" => fingerprint.to_s.strip,
          "job_id" => job_id.to_s.strip,
          "thesis_id" => thesis_id.to_s.strip,
          "source" => normalize_source(source, repository)
        }
      end

      def thesis_value(thesis, key)
        return thesis[key] || thesis[key.to_sym] if thesis.is_a?(Hash)
        thesis.public_send(key) if thesis.respond_to?(key)
      end

      def ensure_root!
        FileUtils.mkdir_p(@root)
        path = @root
        loop do
          fsync_directory(path)
          break if path == @project_root

          parent = File.dirname(path)
          break if parent == path

          path = parent
        end
      end

      def lock_path
        File.join(@root, ".lock")
      end

      def outcome(resolution, record, created: false, occurrence_added: false, persisted: false,
                  would_create: false, would_append: false, dry_run: false)
        Outcome.new(
          resolution: resolution, record: record, created: created,
          occurrence_added: occurrence_added, persisted: persisted,
          would_create: would_create, would_append: would_append, dry_run: dry_run
        ).freeze
      end
    end
  end
end
