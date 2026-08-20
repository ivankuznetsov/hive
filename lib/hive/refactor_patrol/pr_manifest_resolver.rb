require "fileutils"
require "json"
require "time"
require "uri"
require "hive/atomic_file"
require "hive/refactor_patrol/github_gateway"
require "hive/refactor_patrol/pr_manifest"

module Hive
  module RefactorPatrol
    # Resolves one merged PR into an immutable, checksummed scope manifest.
    # Manual replay and future daemon intake share this exact boundary.
    class PrManifestResolver
      SCHEMA = PrManifest::SCHEMA
      SCHEMA_VERSION = PrManifest::SCHEMA_VERSION
      FILE_STATUSES = PrManifest::FILE_STATUSES

      class Conflict < Hive::ConfigError; end
      Resolution = Data.define(:manifests, :classification) do
        def manifest = manifests.one? ? manifests.first : nil
      end

      attr_reader :root

      def initialize(project_root:, registration:, default_branch:, cfg:,
                     gh: Hive::Gh, github_gateway: nil, dry_run: false,
                     hive_state_path: nil)
        @project_root = File.expand_path(project_root)
        @registration = registration.to_s
        @default_branch = default_branch.to_s
        @cfg = cfg
        @github_gateway = GithubGateway.coerce(
          github_gateway,
          transport: gh,
          required: %i[merged_pr_details]
        )
        @dry_run = dry_run
        state_root = hive_state_path || File.join(@project_root, ".hive-state")
        @root = File.join(state_root, "refactor_patrol", "v2", "manifests")
      end

      def resolve(pr, timeout_sec: nil)
        resolve_details(pr, timeout_sec: timeout_sec)
      end

      def resolve_classified(pr, classifier:, target_head: nil, timeout_sec: nil)
        unless classifier.respond_to?(:hydrate)
          raise ArgumentError, "merged-PR classifier must be callable"
        end
        details = fetch_details(pr, timeout_sec: timeout_sec)
        if (existing = existing_manifest(details))
          return Resolution.new(
            manifests: [ existing ],
            classification: {
              "status" => "adopted", "decision" => nil,
              "reason" => "existing_manifest_v#{existing.fetch('schema_version')}"
            }
          )
        end
        classification = classifier.hydrate(
          classification_snapshot(details, target_head: target_head || details.fetch("merge_sha"))
        )
        Resolution.new(manifests: [], classification: classification)
      end

      def preview_classification(pr, classifier:, target_head: nil, timeout_sec: nil)
        unless classifier.respond_to?(:preview)
          raise ArgumentError, "merged-PR classifier must support side-effect-free preview"
        end
        details = fetch_details(pr, timeout_sec: timeout_sec)
        if (existing = existing_manifest(details))
          return Resolution.new(
            manifests: [ existing ],
            classification: {
              "status" => "adopted", "decision" => nil,
              "reason" => "existing_manifest_v#{existing.fetch('schema_version')}"
            }
          )
        end
        Resolution.new(
          manifests: [],
          classification: classifier.preview(
            classification_snapshot(details, target_head: target_head || details.fetch("merge_sha"))
          )
        )
      end

      def materialize_batch(batch, classifications:)
        members = batch.fetch("members")
        indexed = Array(classifications).to_h do |classification|
          [ classification.fetch("occurrence_id"), classification ]
        end
        expected_ids = members.map { |member| member.fetch("occurrence_id") }.uniq
        unless indexed.keys.sort == expected_ids.sort
          raise Conflict, "post-merge batch classifications do not match frozen membership"
        end

        ordered_paths = []
        files_by_path = {}
        members.each do |member|
          classification = indexed.fetch(member.fetch("occurrence_id"))
          snapshot_files = classification.dig("snapshot", "files").to_h do |file|
            [ file.fetch("path"), file ]
          end
          member.fetch("path_mappings").each do |mapping|
            path = mapping.fetch("path")
            file = snapshot_files[path]
            raise Conflict, "post-merge batch member path is absent from its classification" unless file

            ordered_paths << path unless files_by_path.key?(path)
            files_by_path[path] = file
          end
        end
        primary = indexed.fetch(members.first.fetch("occurrence_id"))
        snapshot = primary.fetch("snapshot")
        source = {
          "url" => snapshot.fetch("url"), "number" => snapshot.fetch("number"),
          "repository" => snapshot.fetch("repository"), "registration" => @registration,
          "base_branch" => snapshot.fetch("base_branch"), "base_sha" => snapshot.fetch("base_sha"),
          "merge_sha" => snapshot.fetch("merge_sha"), "merged_at" => snapshot.fetch("merged_at")
        }
        manifest = PrManifest.build(
          source: source,
          files: ordered_paths.map { |path| files_by_path.fetch(path) },
          lane: "post_merge", classification: project_classification(primary),
          provenance: {
            "merges" => members.map do |member|
              member.slice(
                "repository", "number", "merge_sha", "merged_at", "path_mappings"
              ).merge(
                "classification_occurrence_id" => member.fetch("occurrence_id")
              )
            end
          },
          identity: "batch:#{batch.fetch('batch_id')}"
        )
        unless manifest.fetch("job_id") == batch.fetch("owner_job_id")
          raise Conflict, "post-merge batch owner identity is inconsistent"
        end
        publish!(manifest) unless @dry_run
        manifest
      end

      def resolve_details(pr, timeout_sec: nil)
        details = fetch_details(pr, timeout_sec: timeout_sec)
        manifest = build_manifest(details)
        publish!(manifest) unless @dry_run
        manifest
      end

      private

      def fetch_details(pr, timeout_sec:)
        validate_pr_reference!(pr)
        details = @github_gateway.merged_pr_details(
          pr, worktree_path: @project_root, cfg: @cfg, timeout_sec: timeout_sec
        )
        validate_details!(details)
        details
      end

      def existing_manifest(details)
        candidate = build_manifest(details)
        path = manifest_path(candidate.fetch("job_id"))
        return nil unless File.file?(path)

        existing = PrManifest.load!(
          path, expected_job_id: candidate.fetch("job_id"),
          registration: @registration, default_branch: @default_branch
        )
        unless existing.fetch("source") == candidate.fetch("source") &&
               existing.fetch("changed_paths") == candidate.fetch("changed_paths")
          raise Conflict, "refactor patrol manifest conflict for #{candidate.fetch('job_id')}"
        end
        expected_files = if existing.fetch("schema_version") == PrManifest::SCHEMA_VERSION
          details.fetch("files").map(&:compact)
        else
          candidate.fetch("files")
        end
        unless existing.fetch("files") == expected_files
          raise Conflict, "refactor patrol manifest conflict for #{candidate.fetch('job_id')}"
        end
        existing
      rescue PrManifest::Invalid => error
        raise Conflict, error.message
      end

      def manifest_path(job_id)
        File.join(root, "#{job_id}.json")
      end
      public :manifest_path

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
        return if PrManifest.valid_relative_path?(path)

        raise Hive::GhError, "PR #{number} contains unsafe repository path #{path.to_s.inspect}"
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
        files = details.fetch("files").map(&:compact).map do |file|
          file.reject { |key, _value| key == "patch" }
        end
        PrManifest.build(source: source, files: files)
      end

      def project_classification(classification)
        {
          "occurrence_id" => classification.fetch("occurrence_id"),
          "snapshot_digest" => classification.fetch("snapshot_digest"),
          "changed_paths_digest" => classification.fetch("changed_paths_digest"),
          "decision" => classification.fetch("decision"),
          "reason" => classification.fetch("reason"),
          "rationale" => classification.fetch("rationale"),
          "evidence" => classification.fetch("evidence"),
          "model_receipt" => classification.fetch("model_receipt"),
          "attempts" => classification.fetch("attempts"),
          "classified_at" => classification.fetch("updated_at"),
          "prefilter" => classification.fetch("prefilter")
        }
      end

      def classification_snapshot(details, target_head:)
        files = details.fetch("files").map do |file|
          file.slice("path", "status", "patch", "previous_path")
        end
        {
          "repository" => details.fetch("repository"),
          "number" => details.fetch("number"), "url" => details.fetch("url"),
          "base_branch" => details.fetch("base_branch"), "base_sha" => details.fetch("base_sha"),
          "merge_sha" => details.fetch("merge_sha"), "merged_at" => details.fetch("merged_at"),
          "target_head" => target_head.to_s, "title" => details.fetch("title"),
          "body" => details.fetch("body"), "labels" => details.fetch("labels"),
          "author" => details.fetch("author"),
          "changed_paths" => files.map { |file| file.fetch("path") }, "files" => files,
          "publication_provenance" => details.fetch("publication_provenance")
        }
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
    end
  end
end
