require "digest"
require "hive/honeycomb"

module Hive
  module Honeycomb
    class Manifest
      ROOT_KEYS = %w[version files permissions].freeze
      REQUIRED_KEYS = %w[version files].freeze
      PERMISSION_KEYS = %w[presets tools dirs bash yolo].freeze
      FILE_HASH_RE = /\A[0-9a-f]{64}\z/

      attr_reader :files, :permissions

      def self.load(raw)
        parsed = Honeycomb.safe_yaml_load(raw, label: "honeycomb manifest", error_class: ManifestError)
        new(parsed)
      end

      def self.package_digest(files)
        canonical = files.sort.map { |path, hash| "#{path}\0#{hash}\n" }.join
        Digest::SHA256.hexdigest(canonical)
      end

      def self.normalize_path(path)
        unless path.is_a?(String) && !path.empty? && path.valid_encoding?
          raise ManifestError, "manifest path #{path.inspect} must be a non-empty UTF-8 string"
        end
        if path.include?("\0") || path.include?("\\") || path.start_with?("/") || path.end_with?("/")
          raise ManifestError, "manifest path #{path.inspect} is not a normalized POSIX-relative path"
        end
        segments = path.split("/", -1)
        if segments.any? { |segment| segment.empty? || segment == "." || segment == ".." }
          raise ManifestError, "manifest path #{path.inspect} is not a normalized POSIX-relative path"
        end
        normalized = path.unicode_normalize(:nfc)
        unless normalized == path
          raise ManifestError, "manifest path #{path.inspect} changes under Unicode normalization"
        end
        path
      rescue Encoding::CompatibilityError, ArgumentError => e
        raise ManifestError, "manifest path #{path.inspect} is invalid: #{e.message}"
      end

      def initialize(data)
        root = mapping!(data, "manifest")
        missing = REQUIRED_KEYS - root.keys
        unknown = root.keys - ROOT_KEYS
        raise ManifestError, "manifest missing key(s) #{missing.inspect}" unless missing.empty?
        raise ManifestError, "manifest contains unknown key(s) #{unknown.inspect}" unless unknown.empty?
        raise ManifestError, "manifest version must be #{MANIFEST_VERSION}" unless root["version"] == MANIFEST_VERSION

        @files = parse_files(root["files"])
        @permissions = parse_permissions(root.fetch("permissions", {}))
      end

      def package_digest = self.class.package_digest(files)

      private

      def parse_files(value)
        inventory = mapping!(value, "manifest files")
        raise ManifestError, "manifest files must not be empty" if inventory.empty?
        normalized = {}
        inventory.each do |path, raw_hash|
          clean = self.class.normalize_path(path)
          raise ManifestError, "manifest must not inventory manifest.yml" if clean == "manifest.yml"
          raise ManifestError, "manifest contains duplicate normalized path #{clean.inspect}" if normalized.key?(clean)
          hash = raw_hash.to_s.downcase
          unless raw_hash.is_a?(String) && FILE_HASH_RE.match?(hash)
            raise ManifestError, "manifest file hash for #{clean.inspect} must be SHA-256 hex"
          end
          normalized[clean] = hash
        end
        raise ManifestError, "manifest inventory must include workflow.yml" unless normalized.key?("workflow.yml")
        normalized.sort.to_h.freeze
      end

      def parse_permissions(value)
        summary = mapping!(value, "manifest permissions")
        unknown = summary.keys - PERMISSION_KEYS
        raise ManifestError, "manifest permissions contains unknown key(s) #{unknown.inspect}" unless unknown.empty?

        presets = string_array(summary.fetch("presets", []), "permissions presets")
        unless (presets - %w[inherited read-only scoped yolo]).empty?
          raise ManifestError, "manifest permissions presets contains an unknown preset"
        end
        parsed = {
          "presets" => presets.sort.freeze,
          "tools" => string_array(summary.fetch("tools", []), "permissions tools").sort.freeze,
          "dirs" => string_array(summary.fetch("dirs", []), "permissions dirs").sort.freeze,
          "bash" => boolean(summary.fetch("bash", false), "permissions bash"),
          "yolo" => boolean(summary.fetch("yolo", false), "permissions yolo")
        }
        parsed.freeze
      end

      def mapping!(value, label)
        raise ManifestError, "#{label} must be a mapping" unless value.is_a?(Hash)
        value.each_key do |key|
          raise ManifestError, "#{label} contains non-string key #{key.inspect}" unless key.is_a?(String)
        end
        value
      end

      def string_array(value, label)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
          raise ManifestError, "#{label} must be an array of non-empty strings"
        end
        raise ManifestError, "#{label} contains duplicate values" unless value.uniq.length == value.length
        value
      end

      def boolean(value, label)
        return value if value == true || value == false
        raise ManifestError, "#{label} must be boolean"
      end
    end
  end
end
