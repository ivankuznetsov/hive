require "digest"
require "pathname"
require "psych"
require "uri"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/diagnostic"
require "hive/workflow_package/manifest"

module Hive
  module WorkflowPackage
    class RegistryManifest
      FILE_NAME = "manifest.yml".freeze
      SCHEMA = "honeycomb-manifest/v1".freeze
      NAME = /\A[a-z0-9][a-z0-9-]{1,62}[a-z0-9]\z/
      SEMVER = /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
      REVISION = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
      RISKS = %w[low moderate high].freeze
      CAPABILITIES = %w[filesystem-read filesystem-write network shell].freeze
      CORE_KEYS = CanonicalYAML::MANIFEST_KEYS.freeze
      PERMISSION_KEYS = %w[risk capabilities network_hosts filesystem_read filesystem_write secrets].freeze

      attr_reader :data, :bytes, :digest

      def self.load(path)
        bytes = File.binread(path)
        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        fail!("manifest.invalid_yaml", FILE_NAME, "manifest is not valid UTF-8 YAML") unless utf8.valid_encoding?
        data = Psych.safe_load(utf8, permitted_classes: [], permitted_symbols: [], aliases: false)
        validate_shape!(data)
        canonical = CanonicalYAML.dump_manifest(data)
        fail!("manifest.non_canonical", FILE_NAME, "manifest must use canonical Honeycomb YAML") unless bytes == canonical
        release_input = data.reject { |key, _value| key == "release_sha256" }
        expected = ::Digest::SHA256.hexdigest(CanonicalYAML.dump_manifest(release_input, include_release: false))
        unless secure_equal?(data.fetch("release_sha256"), expected)
          fail!("manifest.release_digest_mismatch", FILE_NAME, "release_sha256 does not match canonical manifest content")
        end
        new(data, bytes)
      rescue Psych::Exception, EncodingError
        fail!("manifest.invalid_yaml", FILE_NAME, "manifest is not safe canonical UTF-8 YAML")
      rescue Errno::ENOENT, Errno::EACCES, IOError
        fail!("manifest.unreadable", FILE_NAME, "manifest is missing or unreadable")
      end

      def self.validate_shape!(data)
        fail!("manifest.invalid_type", FILE_NAME, "manifest root must be a map") unless data.is_a?(Hash)
        unless data.keys.all? { |key| key.is_a?(String) } &&
               (data.keys - CORE_KEYS).all? { |key| CanonicalYAML::EXTENSION_PATTERN.match?(key) } &&
               (CORE_KEYS - data.keys).empty?
          fail!("manifest.invalid_shape", FILE_NAME, "manifest has missing or unsupported keys")
        end
        fail!("manifest.unsupported_version", FILE_NAME, "unsupported Honeycomb manifest schema; upgrade Hive") unless data["schema"] == SCHEMA
        fail!("manifest.invalid_name", FILE_NAME, "name is malformed") unless data["name"].is_a?(String) && NAME.match?(data["name"])
        fail!("manifest.invalid_version", FILE_NAME, "version is malformed") unless data["version"].is_a?(String) && SEMVER.match?(data["version"])
        %w[description license hive_min_version].each { |key| required_string!(data[key], key) }
        fail!("manifest.invalid_version", FILE_NAME, "hive_min_version is malformed") unless SEMVER.match?(data["hive_min_version"])
        validate_author!(data["author"])
        validate_source!(data["source"])
        validate_permissions!(data["permissions"])
        validate_files!(data["files"], data["name"], data["version"])
        fail!("manifest.invalid_hash", FILE_NAME, "release_sha256 is malformed") unless Manifest::SHA256.match?(data["release_sha256"].to_s)
        data
      end

      def self.validate_author!(author)
        unless author.is_a?(Hash) && author.keys.sort == %w[name url]
          fail!("manifest.invalid_author", FILE_NAME, "author must contain only name and url")
        end
        required_string!(author["name"], "author.name")
        validate_url!(author["url"], "author.url")
      end

      def self.validate_source!(source)
        unless source.is_a?(Hash) && source.keys.sort == %w[revision url]
          fail!("manifest.invalid_source", FILE_NAME, "source must contain only revision and url")
        end
        validate_url!(source["url"], "source.url")
        unless source["revision"].is_a?(String) && REVISION.match?(source["revision"])
          fail!("manifest.invalid_source", FILE_NAME, "source revision must be a full immutable SHA")
        end
      end

      def self.validate_permissions!(permissions)
        unless permissions.is_a?(Hash) && permissions.keys.sort == PERMISSION_KEYS.sort
          fail!("manifest.invalid_permissions", FILE_NAME, "permissions disclosure is malformed")
        end
        fail!("manifest.invalid_permissions", FILE_NAME, "permission risk is malformed") unless RISKS.include?(permissions["risk"])
        validate_string_set!(permissions["capabilities"], "permissions.capabilities", allowed: CAPABILITIES)
        %w[network_hosts filesystem_read filesystem_write secrets].each do |key|
          validate_string_set!(permissions[key], "permissions.#{key}")
        end
      end

      def self.validate_files!(files, name, version)
        fail!("manifest.invalid_files", FILE_NAME, "files must be a non-empty map") unless files.is_a?(Hash) && !files.empty?
        prefix = "packages/#{name}/#{version}/"
        paths = files.keys
        fail!("manifest.invalid_files", FILE_NAME, "file paths must be sorted") unless paths == paths.sort
        paths.each do |path|
          unless path.is_a?(String) && path.start_with?(prefix) && path != "#{prefix}#{FILE_NAME}"
            fail!("package.path_escape", path.to_s, "manifest file path must stay inside its immutable version directory")
          end
          relative = path.delete_prefix(prefix)
          validate_relative_path!(relative)
          fail!("manifest.invalid_hash", path, "file sha256 is malformed") unless Manifest::SHA256.match?(files[path].to_s)
        end
      end

      def self.validate_relative_path!(value)
        parts = value.split("/")
        invalid = value.empty? || value.include?("\\") || value.include?("\0") || Pathname.new(value).absolute? ||
                  parts.any? { |part| part.empty? || part == "." || part == ".." } || Pathname.new(value).cleanpath.to_s != value
        fail!("package.path_escape", value, "package path must be normalized and remain inside the package") if invalid
      end

      def self.validate_string_set!(value, label, allowed: nil)
        unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) && !entry.empty? } && value == value.uniq.sort
          fail!("manifest.invalid_permissions", FILE_NAME, "#{label} must be a sorted set of non-empty strings")
        end
        if value.include?("*") && value.length > 1
          fail!("manifest.invalid_permissions", FILE_NAME, "#{label} wildcard must be the only value")
        end
        if allowed && (value - allowed).any?
          fail!("manifest.invalid_permissions", FILE_NAME, "#{label} contains unsupported values")
        end
      end

      def self.required_string!(value, label)
        return if value.is_a?(String) && !value.strip.empty?
        fail!("manifest.invalid_value", FILE_NAME, "#{label} must be a non-empty string")
      end

      def self.validate_url!(value, label)
        uri = URI.parse(value.to_s)
        valid = %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? && uri.userinfo.nil? && uri.fragment.nil?
        fail!("manifest.invalid_url", FILE_NAME, "#{label} must be an absolute HTTP(S) URL") unless valid
      rescue URI::InvalidURIError
        fail!("manifest.invalid_url", FILE_NAME, "#{label} must be an absolute HTTP(S) URL")
      end

      def self.secure_equal?(left, right)
        left.is_a?(String) && left.bytesize == right.bytesize &&
          left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

      def self.fail!(rule, path, message)
        raise PackageError, Diagnostic.new(rule_id: rule, severity: :error, path: path, message: message)
      end

      def initialize(data, bytes)
        @data = data.freeze
        @bytes = bytes.freeze
        @digest = data.fetch("release_sha256").freeze
        freeze
      end

      def file_entries
        prefix = "packages/#{data.fetch('name')}/#{data.fetch('version')}/"
        data.fetch("files").map do |path, sha256|
          { "path" => path.delete_prefix(prefix), "sha256" => sha256 }
        end
      end

      def file_name = FILE_NAME
      def descriptor = "workflow.yml"
      def summary = data.fetch("description")
      def permissions = data.fetch("permissions")
    end
  end
end
