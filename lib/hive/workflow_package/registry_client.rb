require "fileutils"
require "json"
require "open3"
require "timeout"
require "tmpdir"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/manifest"
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
        :manifest_digest, :summary, :permissions
      )

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
          unless git_success?("-C", checkout, "merge-base", "--is-ancestor",
                              resolution.source_commit, catalog_commit)
            raise RegistryError, "catalog-listed source commit is not an ancestor of the catalog snapshot"
          end
          materialize(checkout, resolution, destination)
          result = Validator.validate!(
            destination,
            expected_name: name,
            expected_manifest_digest: resolution.manifest_digest
          )
          raise RegistryError, result.errors.first.to_s unless result.valid?

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

      def parse_catalog(bytes)
        data = JSON.parse(bytes)
        unless bytes == CanonicalJSON.generate(data)
          raise RegistryError, "official catalog is not canonical JSON"
        end
        unless data.is_a?(Hash) && data.keys.sort == %w[registry schema_version workflows] &&
               data["schema_version"] == 1 && data["registry"] == "honeycomb" && data["workflows"].is_a?(Hash)
          raise RegistryError, "official catalog has an unsupported or malformed schema"
        end
        data
      rescue JSON::ParserError, EncodingError
        raise RegistryError, "official catalog is not valid UTF-8 JSON"
      end

      def resolve_catalog(catalog, name, requested_ref, catalog_commit)
        workflow = catalog.fetch("workflows").fetch(name) do
          raise RegistryError, "workflow honeycomb/#{name} is not listed"
        end
        unless workflow.is_a?(Hash) && workflow.keys.sort == %w[latest versions] && workflow["versions"].is_a?(Hash)
          raise RegistryError, "catalog entry for honeycomb/#{name} is malformed"
        end
        versions = workflow.fetch("versions")
        version = if requested_ref.nil?
                    workflow.fetch("latest")
        elsif versions.key?(requested_ref)
                    requested_ref
        elsif FULL_SHA.match?(requested_ref)
                    versions.find { |_candidate, entry| entry.is_a?(Hash) && entry["source_commit"] == requested_ref }&.first
        end
        raise RegistryError, "requested workflow ref is mutable, abbreviated, or not listed" unless version

        entry = versions.fetch(version)
        validate_version_entry!(entry)
        Resolution.new(
          name: name,
          version: version,
          source_commit: entry.fetch("source_commit"),
          catalog_commit: catalog_commit,
          manifest_digest: entry.fetch("manifest_digest"),
          summary: entry.fetch("summary"),
          permissions: entry.fetch("permissions")
        ).freeze
      rescue KeyError
        raise RegistryError, "catalog entry for honeycomb/#{name} is malformed"
      end

      def validate_version_entry!(entry)
        required = %w[manifest_digest permissions source_commit summary]
        unless entry.is_a?(Hash) && entry.keys.sort == required
          raise RegistryError, "catalog version entry is malformed"
        end
        validate_full_sha!(entry["source_commit"], "source commit")
        unless entry["manifest_digest"].is_a?(String) && Manifest::SHA256.match?(entry["manifest_digest"])
          raise RegistryError, "catalog manifest digest is malformed"
        end
        raise RegistryError, "catalog summary is malformed" unless entry["summary"].is_a?(String) && !entry["summary"].empty?
        Manifest.validate_permissions!(entry["permissions"])
      rescue PackageError
        raise RegistryError, "catalog permission disclosure is malformed"
      end

      def materialize(checkout, resolution, destination)
        prefix = "workflows/#{resolution.name}/"
        manifest_path = "#{prefix}manifest.json"
        manifest_bytes = git!("-C", checkout, "show", "#{resolution.source_commit}:#{manifest_path}", binary: true)
        manifest = parse_manifest_bytes(manifest_bytes)
        expected_paths = [ "manifest.json" ] + manifest.data.fetch("files").map { |entry| entry.fetch("path") }
        tree = git!("-C", checkout, "ls-tree", "-r", "-z", resolution.source_commit, "--", prefix, binary: true)
        tree_paths = parse_tree(tree, prefix)
        unless tree_paths.sort == expected_paths.sort
          raise RegistryError, "source commit package tree does not match its complete manifest inventory"
        end

        FileUtils.mkdir_p(destination, mode: 0o700)
        expected_paths.each do |relative|
          bytes = relative == "manifest.json" ? manifest_bytes :
            git!("-C", checkout, "show", "#{resolution.source_commit}:#{prefix}#{relative}", binary: true)
          target = File.join(destination, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          File.binwrite(target, bytes)
        end
      end

      def parse_manifest_bytes(bytes)
        Dir.mktmpdir("hive-honeycomb-manifest-") do |dir|
          path = File.join(dir, Manifest::FILE_NAME)
          File.binwrite(path, bytes)
          return Manifest.load(path)
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

      def git_success?(*args)
        _out, _err, status = Timeout.timeout(@timeout_sec) do
          Open3.capture3({ "LC_ALL" => "C", "LANG" => "C" }, "git", *args)
        end
        status.success?
      rescue Timeout::Error, Errno::ENOENT, Errno::EACCES
        false
      end
    end
  end
end
