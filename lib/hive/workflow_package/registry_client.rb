require "fileutils"
require "json"
require "open3"
require "timeout"
require "tmpdir"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_manifest"
require "hive/workflow_package/validator"

module Hive
  module WorkflowPackage
    class RegistryError < Hive::Error
      def exit_code = Hive::ExitCodes::UNAVAILABLE
    end

    class RegistryClient
      OFFICIAL_REPOSITORY = "https://github.com/ivankuznetsov/honeycomb.git".freeze
      SOURCE = %r{\Ahoneycomb/(?<name>[a-z0-9][a-z0-9-]*)(?:@(?<ref>[^/\s]+))?\z}
      FULL_SHA = /\A[0-9a-f]{40}\z/
      TIMEOUT_SEC = 30

      Resolution = Data.define(
        :name, :version, :source_commit, :catalog_commit,
        :source_revision, :manifest_digest, :hive_min_version, :summary, :permissions
      )

      CATALOG_SCHEMA = "honeycomb-catalog/v2".freeze
      ENTRY_KEYS = %w[
        name version latest_version description release_tier current_tier
        permission_risk state discoverable exact_resolution verification history
        advisories author license hive_min_version permissions install_command
        package_url reviews_url community_reviews_url source_sha listing_approval
      ].freeze
      LISTING_APPROVAL_KEYS = %w[
        release_sha256 head_sha lint_checked_at approved_by approved_at reviews
      ].freeze
      STATES = %w[listed soft_hidden yanked revoked].freeze

      def initialize(repository: OFFICIAL_REPOSITORY, timeout_sec: TIMEOUT_SEC)
        @repository = repository
        @timeout_sec = timeout_sec
      end

      def fetch(source, destination:)
        name, requested_ref = parse_source(source)
        destination = File.expand_path(destination)
        raise RegistryError, "registry destination must be empty" if File.exist?(destination) && !Dir.empty?(destination)

        Dir.mktmpdir("hive-honeycomb-registry-") do |checkout|
          git!("clone", "--quiet", "--no-checkout", "--", @repository, checkout)
          catalog_commit = git!("-C", checkout, "rev-parse", "HEAD").strip
          validate_full_sha!(catalog_commit, "catalog commit")
          catalog_bytes = git!("-C", checkout, "show", "#{catalog_commit}:catalog.json", binary: true)
          catalog = parse_catalog(catalog_bytes)
          resolution = resolve_catalog(catalog, name, requested_ref, catalog_commit)
          materialize(checkout, resolution, destination)
          result = Validator.validate!(
            destination,
            expected_name: name,
            expected_manifest_digest: resolution.manifest_digest
          )
          raise RegistryError, result.errors.first.to_s unless result.valid?
          bind_catalog_metadata!(resolution, result.manifest)

          resolution
        end
      rescue StandardError
        FileUtils.rm_rf(destination) if destination
        FileUtils.mkdir_p(destination) if destination
        raise
      end

      def parse_source(source)
        match = SOURCE.match(source.to_s)
        raise RegistryError, "workflow source must be honeycomb/<name>[@version-or-full-sha]" unless match

        [ match[:name], match[:ref] ]
      end

      private

      def bind_catalog_metadata!(resolution, manifest)
        data = manifest.data
        matches = data.fetch("version") == resolution.version &&
                  manifest.summary == resolution.summary &&
                  manifest.permissions == resolution.permissions &&
                  data.dig("source", "revision") == resolution.source_revision &&
                  data.fetch("hive_min_version") == resolution.hive_min_version &&
                  data.fetch("release_sha256") == resolution.manifest_digest
        raise RegistryError, "catalog metadata does not match the verified manifest" unless matches
      rescue KeyError
        raise RegistryError, "verified manifest metadata is incomplete"
      end

      def parse_catalog(bytes)
        data = JSON.parse(bytes)
        unless bytes == CanonicalJSON.generate(data)
          raise RegistryError, "official catalog is not canonical JSON"
        end
        unless data.is_a?(Hash) && data.keys.sort == %w[entries schema] &&
               data["schema"] == CATALOG_SCHEMA && data["entries"].is_a?(Array)
          raise RegistryError, "official catalog has an unsupported or malformed schema"
        end
        seen = {}
        data["entries"].each do |entry|
          validate_version_entry!(entry)
          identity = [ entry.fetch("name"), entry.fetch("version") ]
          raise RegistryError, "official catalog contains a duplicate version entry" if seen[identity]
          seen[identity] = true
        end
        data
      rescue JSON::ParserError, EncodingError
        raise RegistryError, "official catalog is not valid UTF-8 JSON"
      end

      def resolve_catalog(catalog, name, requested_ref, catalog_commit)
        entries = catalog.fetch("entries").select { |entry| entry.is_a?(Hash) && entry["name"] == name }
        raise RegistryError, "workflow honeycomb/#{name} is not listed" if entries.empty?

        entry = if requested_ref.nil?
                  latest = entries.map { |candidate| candidate["latest_version"] }.compact.uniq
                  candidate = latest.one? && entries.find do |item|
                    item["version"] == latest.first && item["state"] == "listed" && item["discoverable"] == true
                  end
                  candidate
        elsif RegistryManifest::SEMVER.match?(requested_ref)
                  entries.find { |candidate| candidate["version"] == requested_ref }
        elsif RegistryManifest::REVISION.match?(requested_ref)
                  matches = entries.select { |candidate| candidate["source_sha"] == requested_ref }
                  raise RegistryError, "requested full source SHA is ambiguous across catalog versions" if matches.length > 1
                  matches.first
        end
        raise RegistryError, "requested workflow ref is mutable, abbreviated, or not listed" unless entry
        if entry["state"] == "revoked" || entry["exact_resolution"] == "blocked"
          advisory_ids = entry.fetch("advisories").filter_map { |advisory| advisory["id"] }.join(", ")
          suffix = advisory_ids.empty? ? "" : " (#{advisory_ids})"
          raise RegistryError, "honeycomb/#{name}@#{entry.fetch('version')} is revoked#{suffix}"
        end

        Resolution.new(
          name: name,
          version: entry.fetch("version"),
          source_commit: catalog_commit,
          catalog_commit: catalog_commit,
          source_revision: entry.fetch("source_sha"),
          manifest_digest: entry.dig("listing_approval", "release_sha256"),
          hive_min_version: entry.fetch("hive_min_version"),
          summary: entry.fetch("description"),
          permissions: entry.fetch("permissions")
        ).freeze
      rescue KeyError
        raise RegistryError, "catalog entry for honeycomb/#{name} is malformed"
      end

      def validate_version_entry!(entry)
        unless entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS.sort
          raise RegistryError, "catalog version entry is malformed"
        end
        unless RegistryManifest::NAME.match?(entry["name"].to_s) && RegistryManifest::SEMVER.match?(entry["version"].to_s)
          raise RegistryError, "catalog version identity is malformed"
        end
        if entry["latest_version"] && !RegistryManifest::SEMVER.match?(entry["latest_version"].to_s)
          raise RegistryError, "catalog latest version is malformed"
        end
        unless RegistryManifest::SEMVER.match?(entry["hive_min_version"].to_s)
          raise RegistryError, "catalog Hive minimum version is malformed"
        end
        unless STATES.include?(entry["state"]) && entry["discoverable"] == (entry["state"] == "listed") &&
               entry["exact_resolution"] == (entry["state"] == "revoked" ? "blocked" : "allowed")
          raise RegistryError, "catalog lifecycle entry is malformed"
        end
        unless %w[community verified].include?(entry["release_tier"]) &&
               %w[community verified].include?(entry["current_tier"]) &&
               RegistryManifest::RISKS.include?(entry["permission_risk"])
          raise RegistryError, "catalog trust entry is malformed"
        end
        raise RegistryError, "catalog description is malformed" unless entry["description"].is_a?(String) && !entry["description"].empty?
        unless entry["author"].is_a?(Hash) && entry["author"].keys.sort == %w[name url] &&
               entry["author"].values.all? { |value| value.is_a?(String) && !value.empty? }
          raise RegistryError, "catalog author is malformed"
        end
        RegistryManifest.validate_permissions!(entry["permissions"])
        unless entry["permission_risk"] == entry.dig("permissions", "risk")
          raise RegistryError, "catalog permission risk does not match its disclosure"
        end
        unless RegistryManifest::REVISION.match?(entry["source_sha"].to_s)
          raise RegistryError, "catalog source revision is malformed"
        end
        validate_listing_approval!(entry["listing_approval"])
        unless entry["history"].is_a?(Array) && entry["advisories"].is_a?(Array) &&
               entry["install_command"] == "hive workflow install honeycomb/#{entry.fetch('name')}"
          raise RegistryError, "catalog audit or install metadata is malformed"
        end
      rescue PackageError
        raise RegistryError, "catalog permission disclosure is malformed"
      end

      def validate_listing_approval!(approval)
        unless approval.is_a?(Hash) && approval.keys.sort == LISTING_APPROVAL_KEYS.sort &&
               Manifest::SHA256.match?(approval["release_sha256"].to_s) &&
               RegistryManifest::REVISION.match?(approval["head_sha"].to_s) &&
               approval["approved_by"].is_a?(Array) && !approval["approved_by"].empty? &&
               approval["reviews"].is_a?(Array) && !approval["reviews"].empty?
          raise RegistryError, "catalog listing approval is malformed"
        end
      end

      def materialize(checkout, resolution, destination)
        prefix = "packages/#{resolution.name}/#{resolution.version}/"
        manifest_path = "#{prefix}#{RegistryManifest::FILE_NAME}"
        manifest_bytes = git!("-C", checkout, "show", "#{resolution.catalog_commit}:#{manifest_path}", binary: true)
        manifest = parse_manifest_bytes(manifest_bytes)
        expected_paths = [ RegistryManifest::FILE_NAME ] + manifest.file_entries.map { |entry| entry.fetch("path") }
        tree = git!("-C", checkout, "ls-tree", "-r", "-z", resolution.catalog_commit, "--", prefix, binary: true)
        tree_paths = parse_tree(tree, prefix)
        unless tree_paths.sort == expected_paths.sort
          raise RegistryError, "source commit package tree does not match its complete manifest inventory"
        end

        FileUtils.mkdir_p(destination, mode: 0o700)
        expected_paths.each do |relative|
          bytes = relative == RegistryManifest::FILE_NAME ? manifest_bytes :
            git!("-C", checkout, "show", "#{resolution.catalog_commit}:#{prefix}#{relative}", binary: true)
          target = File.join(destination, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          File.binwrite(target, bytes)
        end
      end

      def parse_manifest_bytes(bytes)
        Dir.mktmpdir("hive-honeycomb-manifest-") do |dir|
          path = File.join(dir, RegistryManifest::FILE_NAME)
          File.binwrite(path, bytes)
          return RegistryManifest.load(path)
        end
      end

      def parse_tree(bytes, prefix)
        bytes.split("\0").reject(&:empty?).map do |record|
          metadata, path = record.split("\t", 2)
          mode, type, = metadata.split(" ")
          unless type == "blob" && %w[100644 100755].include?(mode) && path&.start_with?(prefix)
            raise RegistryError, "source commit package contains a link or unsupported file type"
          end
          path.delete_prefix(prefix)
        end
      end

      def validate_full_sha!(value, label)
        raise RegistryError, "#{label} is not a full immutable SHA" unless value.is_a?(String) && FULL_SHA.match?(value)
      end

      def git!(*args, binary: false)
        out, err, status = Timeout.timeout(@timeout_sec) do
          Open3.capture3({ "LC_ALL" => "C", "LANG" => "C" }, "git", *args)
        end
        raise RegistryError, "registry git operation failed" unless status.success?

        binary ? out.b : out
      rescue Timeout::Error
        raise RegistryError, "registry git operation timed out after #{@timeout_sec}s"
      rescue Errno::ENOENT, Errno::EACCES
        raise RegistryError, "git is not available for registry access"
      end
    end
  end
end
