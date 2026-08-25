require "digest"
require "json"
require "time"
require "uri"
require "hive"
require "hive/gh/repository_identity"

module Hive
  module RefactorPatrol
    # Shared immutable PR-manifest contract used by intake, scheduling, and
    # daemon execution. Keeping validation and checksumming here prevents a
    # producer and consumer from accepting subtly different artifacts.
    module PrManifest
      SCHEMA = "hive-refactor-patrol-pr-manifest".freeze
      LEGACY_SCHEMA_VERSION = 2
      SCHEMA_VERSION = 3
      V2_TOP_LEVEL_KEYS = %w[
        schema schema_version job_id source files changed_paths manifest_checksum
      ].freeze
      TOP_LEVEL_KEYS = %w[
        schema schema_version job_id lane source files changed_paths classification
        provenance manifest_checksum
      ].freeze
      SOURCE_KEYS = %w[
        url number repository registration base_branch base_sha merge_sha merged_at
      ].freeze
      FILE_STATUSES = %w[added removed modified renamed copied changed unchanged].freeze
      CLASSIFICATION_KEYS = %w[
        occurrence_id snapshot_digest changed_paths_digest decision reason rationale evidence
        model_receipt attempts classified_at prefilter
      ].freeze
      PREFILTER_KEYS = %w[decision reason evidence].freeze
      PROVENANCE_KEYS = %w[merges].freeze
      MERGE_PROVENANCE_KEYS = %w[
        repository number merge_sha merged_at classification_occurrence_id path_mappings
      ].freeze
      PATH_MAPPING_KEYS = %w[path slice_ids].freeze
      DIGEST = /\A[0-9a-f]{64}\z/.freeze

      class Invalid < Hive::ConfigError; end

      module_function

      def build(source:, files:, lane: nil, classification: nil, provenance: nil,
                identity: nil)
        version = classification ? SCHEMA_VERSION : LEGACY_SCHEMA_VERSION
        files = path_inventory(files)
        payload = {
          "schema" => SCHEMA,
          "schema_version" => version,
          "job_id" => job_id(source: source, identity: identity),
          "source" => source,
          "files" => files,
          "changed_paths" => files.map { |file| file.fetch("path") }
        }
        if version == SCHEMA_VERSION
          raise Invalid, "post-merge manifest requires frozen mapped provenance" unless provenance

          payload["lane"] = lane || "post_merge"
          payload["classification"] = classification
          payload["provenance"] = provenance
        end
        payload.merge("manifest_checksum" => checksum(payload))
      end

      def path_inventory(files)
        files.map do |file|
          file.slice("path", "status", "previous_path").compact
        end
      end

      def source_context(manifest)
        context = source_reference(manifest)
        return context unless manifest.fetch("schema_version") == SCHEMA_VERSION

        context.merge(manifest.slice("lane", "classification", "provenance"))
      end

      def source_reference(manifest)
        manifest.fetch("source").merge(
          "changed_paths" => manifest.fetch("changed_paths"),
          "manifest_checksum" => manifest.fetch("manifest_checksum")
        )
      end

      def job_id(source:, identity: nil)
        occurrence_fields = [
          source.fetch("registration"), source.fetch("repository"),
          source.fetch("number"), source.fetch("merge_sha")
        ]
        occurrence_fields << "identity:#{identity}" unless identity.nil?
        occurrence = occurrence_fields.join("\0")
        "pr-#{source.fetch('number')}-#{::Digest::SHA256.hexdigest(occurrence)[0, 16]}"
      end

      def load!(path, expected_job_id: nil, registration: nil, default_branch: nil)
        validate!(
          JSON.parse(File.binread(path)),
          expected_job_id: expected_job_id,
          registration: registration,
          default_branch: default_branch
        )
      rescue JSON::ParserError, SystemCallError, IOError, KeyError, ArgumentError => e
        raise Invalid, "cannot read refactor patrol job manifest (#{e.class}: #{e.message})"
      end

      def validate!(manifest, expected_job_id: nil, registration: nil, default_branch: nil)
        version = manifest.is_a?(Hash) && manifest["schema_version"]
        expected_keys = version == LEGACY_SCHEMA_VERSION ? V2_TOP_LEVEL_KEYS : TOP_LEVEL_KEYS
        unless manifest.is_a?(Hash) && manifest.keys.sort == expected_keys.sort &&
               manifest["schema"] == SCHEMA &&
               [ LEGACY_SCHEMA_VERSION, SCHEMA_VERSION ].include?(version)
          raise Invalid, "refactor patrol job manifest schema is invalid"
        end
        if expected_job_id && manifest.fetch("job_id").to_s != expected_job_id.to_s
          raise Invalid, "refactor patrol job manifest id does not match its filename"
        end

        validate_source!(manifest.fetch("source"), registration: registration, default_branch: default_branch)
        files = manifest.fetch("files")
        changed_paths = manifest.fetch("changed_paths")
        unless files.is_a?(Array) && files.size <= 10_000 &&
               files.all? { |file| valid_file?(file, version: version) } &&
               changed_paths == files.map { |file| file.fetch("path") } && changed_paths.uniq == changed_paths
          raise Invalid, "refactor patrol job manifest file scope is invalid"
        end
        validate_v3!(manifest) if version == SCHEMA_VERSION

        expected = checksum(manifest.reject { |key, _value| key == "manifest_checksum" })
        unless manifest.fetch("manifest_checksum").to_s == expected
          raise Invalid, "refactor patrol job manifest checksum is invalid"
        end
        manifest
      rescue KeyError, ArgumentError => e
        raise Invalid, "refactor patrol job manifest is incomplete (#{e.class}: #{e.message})"
      end

      def checksum(payload)
        ::Digest::SHA256.hexdigest(canonical_json(payload))
      end

      def repository_target(source)
        repository = Hive::Gh::RepositoryIdentity.validated_repository_slug(
          source.fetch("repository")
        )
        number = source.fetch("number")
        uri = URI.parse(source.fetch("url"))
        match = uri.path.match(
          %r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z}
        ) if uri.path.is_a?(String)
        valid = uri.is_a?(URI::HTTP) && uri.host && match &&
                match[1].casecmp?(repository) &&
                number.is_a?(Integer) && number.positive? &&
                match[2].to_i == number && uri.userinfo.nil? &&
                uri.query.nil? && uri.fragment.nil?
        raise Invalid, "refactor patrol job manifest source repository is invalid" unless valid

        Hive::Gh::RepositoryIdentity.github_repository_target(
          repository, uri.host
        )
      rescue Hive::GhError, ArgumentError, KeyError, TypeError,
             URI::InvalidURIError
        raise Invalid,
              "refactor patrol job manifest source repository is invalid"
      end

      def valid_file?(file, version: nil)
        return false unless file.is_a?(Hash)
        allowed = %w[path status previous_path]
        allowed << "patch" if version == SCHEMA_VERSION
        return false unless (file.keys - allowed).empty?
        return false unless %w[path status].all? { |key| file.key?(key) }
        return false unless FILE_STATUSES.include?(file["status"])
        return false if file.key?("patch") &&
                        (!file["patch"].is_a?(String) || !file["patch"].valid_encoding? ||
                         file["patch"].include?("\0"))

        [ file["path"], file["previous_path"] ].compact.all? do |path|
          valid_relative_path?(path) &&
            (version != SCHEMA_VERSION || path.bytesize <= 4_096)
        end
      end

      def valid_relative_path?(path)
        value = path.to_s
        parts = value.split("/", -1)
        !value.empty? && !value.start_with?("/") && !value.include?("\\") &&
          !value.include?("\0") && parts.none? { |part| part.empty? || %w[. ..].include?(part) }
      end

      def canonical_json(value)
        JSON.generate(canonical_json_value(value))
      end

      def canonical_json_value(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [ key, canonical_json_value(value.fetch(key)) ] }
        when Array
          value.map { |item| canonical_json_value(item) }
        else
          value
        end
      end

      def validate_source!(source, registration:, default_branch:)
        unless source.is_a?(Hash) && source.keys.sort == SOURCE_KEYS.sort
          raise Invalid, "refactor patrol job manifest source is invalid"
        end
        if registration && source["registration"] != registration.to_s
          raise Invalid, "refactor patrol job manifest source does not match this registration"
        end
        if default_branch && source["base_branch"] != default_branch.to_s
          raise Invalid, "refactor patrol job manifest source does not match this registration"
        end
        unless source["number"].is_a?(Integer) && source["number"].positive? &&
               (SOURCE_KEYS - [ "number" ]).all? { |key| source[key].is_a?(String) && !source[key].empty? }
          raise Invalid, "refactor patrol job manifest source fields are invalid"
        end
        Time.iso8601(source.fetch("merged_at"))
        repository_target(source)
      end

      def validate_v3!(manifest)
        unless manifest.fetch("lane") == "post_merge"
          raise Invalid, "refactor patrol job manifest lane is invalid"
        end
        classification = manifest.fetch("classification")
        unless classification.is_a?(Hash) && classification.keys.sort == CLASSIFICATION_KEYS.sort &&
               classification["decision"] == "feature" &&
               DIGEST.match?(classification["occurrence_id"].to_s) &&
               DIGEST.match?(classification["snapshot_digest"].to_s) &&
               DIGEST.match?(classification["changed_paths_digest"].to_s) &&
               classification["attempts"].is_a?(Integer) && classification["attempts"].between?(0, 10) &&
               classification["evidence"].is_a?(Array) && classification["evidence"].size <= 16 &&
               classification["evidence"].all? { |item| bounded_string?(item) } &&
               %w[reason rationale model_receipt].all? { |key| bounded_string?(classification[key]) }
          raise Invalid, "refactor patrol job manifest classification is invalid"
        end
        Time.iso8601(classification.fetch("classified_at"))
        prefilter = classification.fetch("prefilter")
        unless prefilter.is_a?(Hash) && prefilter.keys.sort == PREFILTER_KEYS.sort &&
               prefilter["decision"] == "ambiguous" &&
               bounded_string?(prefilter["reason"]) && prefilter["evidence"].is_a?(Array) &&
               prefilter["evidence"].size <= 16 &&
               prefilter["evidence"].all? { |item| bounded_string?(item) }
          raise Invalid, "refactor patrol job manifest prefilter is invalid"
        end
        provenance = manifest.fetch("provenance")
        merges = provenance.is_a?(Hash) && provenance.keys.sort == PROVENANCE_KEYS && provenance["merges"]
        unless merges.is_a?(Array) && merges.size.between?(1, 8)
          raise Invalid, "refactor patrol job manifest provenance is invalid"
        end
        merges.each do |merge|
          unless merge.is_a?(Hash) && merge.keys.sort == MERGE_PROVENANCE_KEYS.sort &&
                 bounded_string?(merge["repository"]) &&
                 valid_repository_slug?(merge["repository"]) &&
                 merge["number"].is_a?(Integer) && merge["number"].positive? &&
                 merge["merge_sha"].to_s.match?(/\A[0-9a-f]{40,64}\z/)
            raise Invalid, "refactor patrol job manifest merge provenance is invalid"
          end
          Time.iso8601(merge.fetch("merged_at"))
          unless DIGEST.match?(merge["classification_occurrence_id"].to_s) &&
                 valid_path_mappings?(merge.fetch("path_mappings"))
            raise Invalid, "refactor patrol job manifest mapped provenance is invalid"
          end
        end
        total_paths = merges.sum { |merge| merge.fetch("path_mappings").size }
        if total_paths > 512
          raise Invalid, "refactor patrol job manifest provenance path bound is exceeded"
        end
        mapped_paths = merges.flat_map do |merge|
          merge.fetch("path_mappings").map { |mapping| mapping.fetch("path") }
        end
        unless mapped_paths.uniq == manifest.fetch("changed_paths")
          raise Invalid, "refactor patrol job manifest provenance does not cover its file scope"
        end
      end

      def bounded_string?(value)
        value.is_a?(String) && !value.empty? && value.bytesize <= 2_000 &&
          value.valid_encoding? && !value.include?("\0")
      end

      def valid_path_mappings?(mappings)
        mappings.is_a?(Array) &&
          mappings.map { |mapping| mapping.is_a?(Hash) && mapping["path"] }.uniq.size == mappings.size &&
          mappings.all? do |mapping|
            mapping.is_a?(Hash) && mapping.keys.sort == PATH_MAPPING_KEYS.sort &&
              valid_relative_path?(mapping["path"]) && mapping["path"].bytesize <= 4_096 &&
              mapping["slice_ids"].is_a?(Array) && mapping["slice_ids"].size.between?(1, 32) &&
              mapping["slice_ids"].uniq == mapping["slice_ids"] &&
              mapping["slice_ids"].all? { |id| bounded_string?(id) && id.bytesize <= 256 }
          end
      end

      def valid_repository_slug?(value)
        Hive::Gh::RepositoryIdentity.validated_repository_slug(value)
        true
      rescue Hive::GhError
        false
      end
      private_class_method :canonical_json_value, :validate_source!, :validate_v3!, :bounded_string?,
                           :valid_path_mappings?,
                           :valid_repository_slug?
    end
  end
end
