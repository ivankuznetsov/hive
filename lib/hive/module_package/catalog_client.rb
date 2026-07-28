require "fileutils"
require "json"
require "open3"
require "timeout"
require "tmpdir"
require "hive/module_package/validator"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/registry_client"

module Hive
  module ModulePackage
    class CatalogError < Hive::Error
      def exit_code = Hive::ExitCodes::UNAVAILABLE
    end

    class CatalogClient
      OFFICIAL_REPOSITORY = Hive::WorkflowPackage::RegistryClient::OFFICIAL_REPOSITORY
      CATALOG_SCHEMA = "honeycomb-catalog/v3".freeze
      SOURCE = /\Ahoneycomb\/(?<name>[a-z0-9][a-z0-9-]*)(?:@(?<ref>[^\/\s]+))?\z/
      ENTRY_KEYS = %w[
        name version latest_version type description state discoverable source_sha
        manifest_sha256 package_path
      ].freeze
      STATES = %w[listed soft_hidden yanked revoked].freeze
      TIMEOUT_SEC = 30

      Resolution = Data.define(
        :name, :version, :type, :source_commit, :catalog_commit, :source_revision,
        :manifest_digest, :summary, :package_path, :descriptor
      )

      def initialize(repository: OFFICIAL_REPOSITORY, timeout_sec: TIMEOUT_SEC)
        @repository = repository
        @timeout_sec = timeout_sec
      end

      def fetch(source, destination:)
        materialized = false
        name, requested_ref = parse_source(source)
        destination = File.expand_path(destination)
        if File.symlink?(destination) || (File.exist?(destination) && !File.directory?(destination))
          raise CatalogError, "module catalog destination must be a real directory"
        end
        if File.exist?(destination) && !Dir.empty?(destination)
          raise CatalogError, "module catalog destination must be empty"
        end

        Dir.mktmpdir("hive-module-catalog-") do |checkout|
          git!("clone", "--quiet", "--no-checkout", "--", @repository, checkout)
          catalog_commit = git!("-C", checkout, "rev-parse", "HEAD").strip
          validate_full_sha!(catalog_commit, "catalog commit")
          catalog_bytes = git!("-C", checkout, "show", "#{catalog_commit}:catalog.json", binary: true)
          schema = catalog_schema(catalog_bytes)
          if schema == Hive::WorkflowPackage::RegistryClient::CATALOG_SCHEMA
            materialized = true
            return fetch_legacy(source, destination)
          end

          catalog = parse_catalog(catalog_bytes)
          resolution = resolve_catalog(catalog, name, requested_ref, catalog_commit)
          materialized = true
          materialize(checkout, resolution, destination)
          result = Validator.validate!(
            destination, expected_name: name,
            expected_manifest_digest: resolution.manifest_digest,
            catalog_commit: catalog_commit
          )
          bind_catalog_metadata!(resolution, result.manifest)
          resolution.with(descriptor: result.descriptor)
        end
      rescue StandardError
        if destination && materialized
          FileUtils.rm_rf(destination)
          FileUtils.mkdir_p(destination, mode: 0o700)
        end
        raise
      end

      def parse_source(source)
        match = SOURCE.match(source.to_s)
        raise CatalogError, "module source must be honeycomb/<name>[@version-or-full-sha]" unless match
        ref = match[:ref]
        if ref && !Manifest::SEMVER.match?(ref) && !Manifest::REVISION.match?(ref)
          raise CatalogError, "requested module ref is mutable, abbreviated, or unreviewed"
        end
        [ match[:name], ref ]
      end

      private

      def fetch_legacy(source, destination)
        client = Hive::WorkflowPackage::RegistryClient.new(repository: @repository, timeout_sec: @timeout_sec)
        resolution = client.fetch(source, destination: destination)
        result = Hive::WorkflowPackage::Validator.validate!(
          destination, expected_name: resolution.name,
          expected_manifest_digest: resolution.manifest_digest
        )
        descriptor = Normalizer.from_honeycomb(result.manifest, resolution: resolution)
        Resolution.new(
          name: resolution.name, version: resolution.version, type: "workflow",
          source_commit: resolution.source_commit, catalog_commit: resolution.catalog_commit,
          source_revision: resolution.source_revision, manifest_digest: resolution.manifest_digest,
          summary: resolution.summary, package_path: "packages/#{resolution.name}/#{resolution.version}",
          descriptor: descriptor
        )
      end

      def catalog_schema(bytes)
        JSON.parse(bytes).fetch("schema")
      rescue JSON::ParserError, KeyError
        raise CatalogError, "official catalog is not valid canonical JSON"
      end

      def parse_catalog(bytes)
        data = JSON.parse(bytes)
        raise CatalogError, "official catalog is not canonical JSON" unless bytes == Hive::WorkflowPackage::CanonicalJSON.generate(data)
        unless data.is_a?(Hash) && data.keys.sort == %w[entries schema] &&
               data["schema"] == CATALOG_SCHEMA && data["entries"].is_a?(Array)
          raise CatalogError, "official catalog has an unsupported or malformed schema"
        end
        seen = {}
        data.fetch("entries").each do |entry|
          validate_entry!(entry)
          identity = [ entry.fetch("name"), entry.fetch("version") ]
          raise CatalogError, "official catalog contains a duplicate module version" if seen[identity]
          seen[identity] = true
        end
        data
      rescue JSON::ParserError, EncodingError
        raise CatalogError, "official catalog is not valid UTF-8 JSON"
      end

      def validate_entry!(entry)
        unless entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS.sort
          raise CatalogError, "module catalog entry is malformed"
        end
        unless Manifest::NAME.match?(entry["name"].to_s) && Manifest::SEMVER.match?(entry["version"].to_s)
          raise CatalogError, "module catalog identity is malformed"
        end
        if entry["latest_version"] && !Manifest::SEMVER.match?(entry["latest_version"].to_s)
          raise CatalogError, "module catalog latest version is malformed"
        end
        unless Manifest::TYPES.include?(entry["type"]) && STATES.include?(entry["state"]) &&
               entry["discoverable"] == (entry["state"] == "listed")
          raise CatalogError, "module catalog lifecycle or type is malformed"
        end
        unless entry["description"].is_a?(String) && !entry["description"].empty? &&
               Manifest::REVISION.match?(entry["source_sha"].to_s) &&
               Manifest::SHA256.match?(entry["manifest_sha256"].to_s)
          raise CatalogError, "module catalog provenance is malformed"
        end
        validate_package_path!(entry["package_path"], entry["name"], entry["version"])
      end

      def validate_package_path!(path, name, version)
        expected = "modules/#{name}/#{version}"
        raise CatalogError, "module catalog package path is malformed" unless path == expected
      end

      def resolve_catalog(catalog, name, requested_ref, catalog_commit)
        entries = catalog.fetch("entries").select { |entry| entry.fetch("name") == name }
        raise CatalogError, "module honeycomb/#{name} is not listed" if entries.empty?
        entry = if requested_ref.nil?
                  latest = entries.map { |candidate| candidate["latest_version"] }.compact.uniq
                  latest.one? && entries.find do |candidate|
                    candidate["version"] == latest.first && candidate["state"] == "listed" && candidate["discoverable"]
                  end
        elsif Manifest::SEMVER.match?(requested_ref)
                  entries.find { |candidate| candidate["version"] == requested_ref }
        else
                  matches = entries.select { |candidate| candidate["source_sha"] == requested_ref }
                  raise CatalogError, "requested full source SHA is ambiguous across module versions" if matches.length > 1
                  matches.first
        end
        raise CatalogError, "requested module ref is mutable, abbreviated, or not listed" unless entry
        raise CatalogError, "honeycomb/#{name}@#{entry.fetch('version')} is revoked" if entry["state"] == "revoked"

        Resolution.new(
          name: name, version: entry.fetch("version"), type: entry.fetch("type"),
          source_commit: catalog_commit, catalog_commit: catalog_commit,
          source_revision: entry.fetch("source_sha"), manifest_digest: entry.fetch("manifest_sha256"),
          summary: entry.fetch("description"), package_path: entry.fetch("package_path"), descriptor: nil
        ).freeze
      end

      def materialize(checkout, resolution, destination)
        prefix = "#{resolution.package_path}/"
        tree = git!("-C", checkout, "ls-tree", "-r", "-z", resolution.catalog_commit, "--", prefix, binary: true)
        entries = parse_tree(tree, prefix)
        raise CatalogError, "reviewed module package is empty" if entries.empty?
        manifest_entries = entries.select do |entry|
          [ Manifest::FILE_NAME, Manifest::ALTERNATE_FILE_NAME ].include?(entry.fetch("path"))
        end
        unless manifest_entries.one?
          raise CatalogError, "reviewed module package must contain exactly one manifest"
        end

        manifest_entry = manifest_entries.first
        manifest_bytes = read_blob(checkout, resolution, prefix, manifest_entry.fetch("path"))
        manifest = parse_manifest_bytes(manifest_bytes, manifest_entry.fetch("path"))
        expected_paths = [ manifest_entry.fetch("path") ] +
          manifest.file_entries.map { |entry| entry.fetch("path") }
        unless entries.map { |entry| entry.fetch("path") }.sort == expected_paths.sort
          raise CatalogError, "reviewed module package tree does not match its complete manifest inventory"
        end

        FileUtils.mkdir_p(destination, mode: 0o700)
        entries.each do |entry|
          relative = entry.fetch("path")
          bytes = relative == manifest_entry.fetch("path") ? manifest_bytes :
            read_blob(checkout, resolution, prefix, relative)
          target = File.join(destination, entry.fetch("path"))
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          File.binwrite(target, bytes)
          File.chmod(0o600, target)
        end
      end

      def parse_tree(bytes, prefix)
        entries = bytes.split("\0").reject(&:empty?).map do |record|
          metadata, path = record.split("\t", 2)
          mode, type, = metadata.split(" ")
          unless type == "blob" && mode == "100644" && path&.start_with?(prefix)
            raise CatalogError, "reviewed module package contains a link or executable file"
          end
          relative = path.delete_prefix(prefix)
          begin
            Manifest.validate_relative_path!(relative, Manifest::FILE_NAME)
          rescue Hive::WorkflowPackage::PackageError
            raise CatalogError, "reviewed module package contains an unsafe path"
          end
          { "path" => relative, "mode" => mode }
        end
        paths = entries.map { |entry| entry.fetch("path") }
        if paths.uniq.length != paths.length || paths.map(&:downcase).uniq.length != paths.length
          raise CatalogError, "reviewed module package contains colliding paths"
        end
        entries
      end

      def parse_manifest_bytes(bytes, file_name)
        Dir.mktmpdir("hive-module-manifest-") do |dir|
          path = File.join(dir, file_name)
          File.binwrite(path, bytes)
          return Manifest.load(path)
        end
      rescue Hive::WorkflowPackage::PackageError => e
        raise CatalogError, "reviewed module package manifest is invalid: #{e.message}"
      end

      def read_blob(checkout, resolution, prefix, relative)
        git!(
          "-C", checkout, "show",
          "#{resolution.catalog_commit}:#{prefix}#{relative}",
          binary: true
        )
      end

      def bind_catalog_metadata!(resolution, manifest)
        matches = manifest.name == resolution.name && manifest.version == resolution.version &&
          manifest.type == resolution.type && manifest.summary == resolution.summary &&
          manifest.data.dig("source", "revision") == resolution.source_revision &&
          manifest.digest == resolution.manifest_digest
        raise CatalogError, "catalog metadata does not match the verified module manifest" unless matches
      end

      def validate_full_sha!(value, label)
        raise CatalogError, "#{label} is not a full immutable SHA" unless Manifest::REVISION.match?(value.to_s)
      end

      def git!(*args, binary: false)
        out, err, status = Timeout.timeout(@timeout_sec) do
          Open3.capture3({ "LC_ALL" => "C", "LANG" => "C" }, "git", *args)
        end
        unless status.success?
          detail = err.to_s.strip.byteslice(0, 1024).to_s
          raise CatalogError, [ "module catalog git operation failed", detail ].reject(&:empty?).join(": ")
        end
        binary ? out.b : out
      rescue Timeout::Error
        raise CatalogError, "module catalog git operation timed out"
      rescue Errno::ENOENT, Errno::EACCES
        raise CatalogError, "git is not available for module catalog access"
      end
    end
  end
end
