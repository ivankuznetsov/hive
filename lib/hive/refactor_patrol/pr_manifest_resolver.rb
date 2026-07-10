require "digest"
require "fileutils"
require "json"
require "time"
require "uri"
require "hive/atomic_file"
require "hive/gh"

module Hive
  module RefactorPatrol
    # Resolves one merged PR into an immutable, checksummed scope manifest.
    # Manual replay and future daemon intake share this exact boundary.
    class PrManifestResolver
      SCHEMA = "hive-refactor-patrol-pr-manifest".freeze
      SCHEMA_VERSION = 2
      FILE_STATUSES = %w[added removed modified renamed copied changed unchanged].freeze

      class Conflict < Hive::ConfigError; end

      attr_reader :root

      def initialize(project_root:, registration:, default_branch:, cfg:, gh: Hive::Gh, dry_run: false)
        @project_root = File.expand_path(project_root)
        @registration = registration.to_s
        @default_branch = default_branch.to_s
        @cfg = cfg
        @gh = gh
        @dry_run = dry_run
        @root = File.join(@project_root, ".hive-state", "refactor_patrol", "v2", "manifests")
      end

      def resolve(pr)
        validate_pr_reference!(pr)
        details = @gh.merged_pr_details(pr, worktree_path: @project_root, cfg: @cfg)
        validate_details!(details)
        manifest = build_manifest(details)
        publish!(manifest) unless @dry_run
        manifest
      end

      def manifest_path(job_id)
        File.join(root, "#{job_id}.json")
      end

      private

      def validate_pr_reference!(pr)
        value = pr.to_s
        return if value.match?(/\A[1-9]\d*\z/)

        uri = URI.parse(value)
        return if %w[http https].include?(uri.scheme) && uri.host && uri.path.match?(%r{/pull/[1-9]\d*\z})

        raise Hive::GhError, "refactor patrol --pr must be a positive PR number or pull-request URL"
      rescue URI::InvalidURIError
        raise Hive::GhError, "refactor patrol --pr must be a positive PR number or pull-request URL"
      end

      def validate_details!(details)
        raise Hive::GhError, "merged PR metadata must be an object" unless details.is_a?(Hash)
        raise Hive::GhError, "PR #{details['number']} is not merged" unless details["state"] == "MERGED"
        unless details["base_branch"] == @default_branch
          raise Hive::GhError,
                "PR #{details['number']} targets #{details['base_branch'].inspect}, not default branch #{@default_branch.inspect}"
        end
        %w[url repository base_sha merge_sha merged_at].each do |key|
          raise Hive::GhError, "merged PR metadata is missing #{key}" if details[key].to_s.empty?
        end
        number = details["number"]
        raise Hive::GhError, "merged PR metadata has invalid number" unless number.is_a?(Integer) && number.positive?
        Time.iso8601(details.fetch("merged_at"))

        files = details["files"]
        count = details["changed_files"]
        unless files.is_a?(Array) && count.is_a?(Integer) && files.size == count
          raise Hive::GhError, "PR #{number} file metadata is incomplete (expected #{count.inspect}, got #{Array(files).size})"
        end
        paths = files.map do |file|
          raise Hive::GhError, "PR #{number} file metadata contains a non-object" unless file.is_a?(Hash)

          validate_file!(file, number)
          file.fetch("path")
        end
        raise Hive::GhError, "PR #{number} file metadata contains duplicate paths" unless paths.uniq.size == paths.size
      rescue ArgumentError, KeyError => e
        raise Hive::GhError, "merged PR metadata is incomplete: #{e.message}"
      end

      def validate_file!(file, number)
        path = file["path"]
        status = file["status"]
        validate_relative_path!(path, number)
        unless FILE_STATUSES.include?(status)
          raise Hive::GhError, "PR #{number} file #{path.inspect} has unsupported status #{status.inspect}"
        end
        validate_relative_path!(file["previous_path"], number) if file.key?("previous_path")
      end

      def validate_relative_path!(path, number)
        value = path.to_s
        components = value.split("/", -1)
        unsafe = value.empty? || value.start_with?("/") || value.include?("\\") || value.include?("\0") ||
                 components.any? { |part| part.empty? || part == "." || part == ".." }
        raise Hive::GhError, "PR #{number} contains unsafe repository path #{value.inspect}" if unsafe
      end

      def build_manifest(details)
        source = {
          "url" => details.fetch("url"),
          "number" => details.fetch("number"),
          "repository" => details.fetch("repository"),
          "registration" => @registration,
          "base_branch" => details.fetch("base_branch"),
          "base_sha" => details.fetch("base_sha"),
          "merge_sha" => details.fetch("merge_sha"),
          "merged_at" => details.fetch("merged_at")
        }
        occurrence = [ @registration, source.fetch("repository"), source.fetch("number"), source.fetch("merge_sha") ].join("\0")
        files = details.fetch("files").map(&:compact)
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "job_id" => "pr-#{source.fetch('number')}-#{::Digest::SHA256.hexdigest(occurrence)[0, 16]}",
          "source" => source,
          "files" => files,
          "changed_paths" => files.map { |file| file.fetch("path") }
        }
        payload.merge("manifest_checksum" => ::Digest::SHA256.hexdigest(canonical_json(payload)))
      end

      def publish!(manifest)
        path = manifest_path(manifest.fetch("job_id"))
        FileUtils.mkdir_p(root)
        lock_path = "#{path}.lock"
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          if File.exist?(path)
            raw = File.binread(path)
            existing = begin
              JSON.parse(raw)
            rescue JSON::ParserError => e
              quarantine_conflict!(
                manifest,
                authoritative_bytes: raw,
                reason: "corrupt_authoritative_manifest"
              )
              raise Conflict, "refactor patrol manifest is corrupt at #{path}: #{e.message}"
            end
            return existing if existing == manifest

            quarantine_conflict!(
              manifest,
              authoritative_bytes: raw,
              reason: "divergent_manifest"
            )
            raise Conflict, "refactor patrol manifest conflict for #{manifest.fetch('job_id')}"
          end

          Hive::AtomicFile.write(path, "#{JSON.pretty_generate(manifest)}\n", mode: 0o600)
          File.open(root, File::RDONLY) { |dir| dir.fsync }
        end
        manifest
      end

      def quarantine_conflict!(manifest, authoritative_bytes:, reason:)
        directory = File.join(File.dirname(root), "quarantine", "manifests")
        checksum = manifest.fetch("manifest_checksum")
        path = File.join(directory, "#{manifest.fetch('job_id')}-#{checksum}.json")
        return path if File.file?(path)

        evidence = {
          "schema" => "hive-refactor-patrol-manifest-conflict",
          "schema_version" => 1,
          "job_id" => manifest.fetch("job_id"),
          "reason" => reason,
          "authoritative_bytes_sha256" => ::Digest::SHA256.hexdigest(authoritative_bytes),
          "candidate_manifest" => manifest
        }
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(evidence)}\n", mode: 0o600)
        File.open(directory, File::RDONLY) { |dir| dir.fsync }
        path
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
    end
  end
end
