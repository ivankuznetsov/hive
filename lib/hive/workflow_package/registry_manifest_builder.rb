require "digest"
require "fileutils"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/permission_projection"
require "hive/workflow_package/registry_manifest"

module Hive
  module WorkflowPackage
    class RegistryManifestBuilder
      Build = Data.define(:manifest, :bytes, :package_digest, :release_digest)

      def self.build!(destination:, name:, version:, metadata:, snapshot:)
        new(
          destination: destination, name: name, version: version,
          metadata: metadata, snapshot: snapshot
        ).build!
      end

      def initialize(destination:, name:, version:, metadata:, snapshot:)
        @destination = File.expand_path(destination)
        @name = name
        @version = version
        @metadata = metadata
        @snapshot = snapshot
      end

      def build!
        ensure_destination!
        write_snapshot!
        files = payload_hashes
        document = {
          "schema" => RegistryManifest::SCHEMA,
          "name" => @name,
          "version" => @version,
          "description" => @metadata.description,
          "author" => @metadata.author,
          "license" => @metadata.license,
          "hive_min_version" => @metadata.hive_min_version,
          "source" => @metadata.source,
          "permissions" => PermissionProjection.derive!(@snapshot.descriptor),
          "files" => files,
          "x-hive" => hive_extension
        }
        release_digest = ::Digest::SHA256.hexdigest(
          CanonicalYAML.dump_manifest(document, include_release: false)
        )
        document["release_sha256"] = release_digest
        bytes = CanonicalYAML.dump_manifest(document)
        path = File.join(@destination, RegistryManifest::FILE_NAME)
        File.binwrite(path, bytes)
        File.chmod(0o644, path)
        manifest = RegistryManifest.load(path)
        Build.new(
          manifest: manifest, bytes: bytes.freeze,
          package_digest: ::Digest::SHA256.hexdigest(bytes).freeze,
          release_digest: release_digest.freeze
        ).freeze
      end

      private

      def ensure_destination!
        if File.exist?(@destination)
          stat = File.lstat(@destination)
          unless stat.directory? && !stat.symlink? && Dir.empty?(@destination)
            raise Hive::ConfigError, "workflow package destination must be an empty real directory"
          end
          File.chmod(0o700, @destination)
        else
          FileUtils.mkdir_p(@destination, mode: 0o700)
        end
      rescue Errno::EACCES, IOError
        raise Hive::ConfigError, "workflow package destination is unavailable"
      end

      def write_snapshot!
        @snapshot.files.each do |relative, record|
          RegistryManifest.validate_relative_path!(relative)
          target = File.join(@destination, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          File.open(target, File::WRONLY | File::CREAT | File::EXCL, record.mode) do |file|
            file.binmode
            file.write(record.bytes)
          end
          File.chmod(record.mode, target)
        end
      rescue PackageError
        raise Hive::ConfigError, "workflow package snapshot contains an unsafe path"
      rescue Errno::EEXIST
        raise Hive::ConfigError, "workflow package builder refuses to overwrite a staged file"
      end

      def payload_hashes
        prefix = "packages/#{@name}/#{@version}/"
        @snapshot.files.keys.sort.to_h do |relative|
          [ "#{prefix}#{relative}", ::Digest::SHA256.file(File.join(@destination, relative)).hexdigest ]
        end
      end

      def hive_extension
        {
          "tools" => @snapshot.tools.map { |path| { "path" => path } },
          "prompt_assets" => @snapshot.prompt_assets.map { |path| { "path" => path } },
          "optional_inputs" => @snapshot.optional_inputs,
          "external_skills" => @snapshot.external_skills
        }
      end
    end
  end
end
