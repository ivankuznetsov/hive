require "digest"
require "find"
require "json"
require "pathname"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/diagnostic"
require "hive/workflows/descriptor_parser"

module Hive
  module WorkflowPackage
    class Manifest
      FILE_NAME = "manifest.json".freeze
      SCHEMA_VERSION = 1
      MAX_FILES = 256
      MAX_FILE_BYTES = 2 * 1024 * 1024
      MAX_PACKAGE_BYTES = 8 * 1024 * 1024
      MAX_DEPTH = 12
      TOP_LEVEL_KEYS = %w[
        schema_version name version summary author descriptor files dependencies permissions
      ].freeze
      METADATA_KEYS = %w[name version summary author descriptor dependencies permissions].freeze
      AUTHOR_KEYS = %w[name url].freeze
      DEPENDENCY_KEYS = %w[hive claude executables].freeze
      PERMISSION_KEYS = %w[
        tools deny directories commands domains credentials
        shell_justification network_justification credential_justification
      ].freeze
      SEMVER = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\z/
      SHA256 = /\A[0-9a-f]{64}\z/

      attr_reader :data, :bytes, :digest

      def self.build(root, metadata:)
        root = File.expand_path(root)
        normalized = normalize_metadata(metadata)
        data = {
          "schema_version" => SCHEMA_VERSION,
          "name" => normalized.fetch("name"),
          "version" => normalized.fetch("version"),
          "summary" => normalized.fetch("summary"),
          "author" => normalized.fetch("author"),
          "descriptor" => normalized.fetch("descriptor", "workflow.yml"),
          "files" => inventory(root),
          "dependencies" => normalized.fetch("dependencies", {}),
          "permissions" => normalized.fetch("permissions", default_permissions)
        }
        new(data)
      end

      def self.load(path)
        bytes = File.binread(path)
        data = JSON.parse(bytes)
        validate_shape!(data)
        canonical = Hive::WorkflowPackage::CanonicalJSON.generate(data)
        unless bytes == canonical
          fail!("manifest.non_canonical", FILE_NAME, "manifest must use canonical JSON with one trailing newline")
        end
        new(data)
      rescue JSON::ParserError, EncodingError
        fail!("manifest.invalid_json", FILE_NAME, "manifest is not valid UTF-8 JSON")
      rescue Errno::ENOENT, Errno::EACCES, IOError
        fail!("manifest.unreadable", FILE_NAME, "manifest is missing or unreadable")
      end

      def self.inventory(root, exclude: [ FILE_NAME ], require_utf8: true)
        root = File.realpath(root)
        entries = []
        seen_case = {}
        total = 0

        Find.find(root) do |absolute|
          next if absolute == root

          relative = Pathname.new(absolute).relative_path_from(Pathname.new(root)).to_s
          stat = File.lstat(absolute)
          fail!("package.path_depth", relative, "package path exceeds maximum depth #{MAX_DEPTH}") if relative.split("/").length > MAX_DEPTH

          if stat.symlink?
            fail!("package.symlink", relative, "symbolic links are not permitted in workflow packages")
          elsif stat.directory?
            next
          elsif !stat.file?
            fail!("package.special_file", relative, "only regular files are permitted in workflow packages")
          end

          validate_relative_path!(relative)
          folded = relative.downcase
          if seen_case.key?(folded) && seen_case.fetch(folded) != relative
            fail!("package.path_case_collision", relative, "package paths must not collide by case")
          end
          seen_case[folded] = relative
          next if Array(exclude).include?(relative)

          fail!("package.hardlink", relative, "hard-linked files are not permitted in workflow packages") if stat.nlink > 1
          fail!("package.file_too_large", relative, "package file exceeds #{MAX_FILE_BYTES} bytes") if stat.size > MAX_FILE_BYTES
          bytes = File.binread(absolute)
          utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
          if require_utf8 && !utf8.valid_encoding?
            fail!("package.invalid_encoding", relative, "package payload files must be valid UTF-8")
          end

          total += stat.size
          fail!("package.too_large", ".", "package exceeds #{MAX_PACKAGE_BYTES} bytes") if total > MAX_PACKAGE_BYTES
          entries << { "path" => relative, "sha256" => ::Digest::SHA256.hexdigest(bytes), "size" => stat.size }
          fail!("package.too_many_files", ".", "package exceeds #{MAX_FILES} payload files") if entries.length > MAX_FILES
        end
        entries.sort_by { |entry| entry.fetch("path") }
      rescue Errno::ENOENT, Errno::EACCES, IOError => e
        fail!("package.unreadable", ".", "package root or payload is unreadable (#{e.class.name.split('::').last})")
      end

      def self.validate_shape!(data)
        fail!("manifest.invalid_type", FILE_NAME, "manifest root must be an object") unless data.is_a?(Hash)
        reject_unknown!(data, TOP_LEVEL_KEYS, label: "manifest")
        fail!("manifest.unsupported_version", FILE_NAME, "unsupported manifest schema version; upgrade Hive") unless data["schema_version"] == SCHEMA_VERSION
        validate_name!(data["name"])
        fail!("manifest.invalid_version", FILE_NAME, "version must be semantic (for example 1.2.3)") unless data["version"].is_a?(String) && SEMVER.match?(data["version"])
        required_string!(data["summary"], "summary")
        validate_author!(data["author"])
        validate_relative_path!(data["descriptor"])
        validate_files!(data["files"])
        validate_dependencies!(data["dependencies"])
        validate_permissions!(data["permissions"])
        data
      end

      def self.normalize_metadata(metadata)
        data = stringify_hash(metadata, "metadata")
        reject_unknown!(data, METADATA_KEYS, label: "metadata")
        data["descriptor"] ||= "workflow.yml"
        data["dependencies"] ||= {}
        data["permissions"] ||= default_permissions
        candidate = {
          "schema_version" => SCHEMA_VERSION,
          "name" => data["name"], "version" => data["version"], "summary" => data["summary"],
          "author" => data["author"], "descriptor" => data["descriptor"], "files" => [],
          "dependencies" => data["dependencies"], "permissions" => data["permissions"]
        }
        validate_shape!(candidate)
        candidate
      end

      def self.validate_name!(value)
        unless value.is_a?(String) && Hive::Workflows::DescriptorParser::SAFE_SLUG.match?(value)
          fail!("manifest.invalid_name", FILE_NAME, "name must be a lowercase workflow slug")
        end
      end

      def self.validate_author!(value)
        author = stringify_hash(value, "author")
        reject_unknown!(author, AUTHOR_KEYS, label: "author")
        required_string!(author["name"], "author.name")
        required_string!(author["url"], "author.url") if author.key?("url")
      end

      def self.validate_dependencies!(value)
        dependencies = stringify_hash(value, "dependencies")
        reject_unknown!(dependencies, DEPENDENCY_KEYS, label: "dependencies")
        %w[hive claude].each { |key| required_string!(dependencies[key], "dependencies.#{key}") if dependencies.key?(key) }
        string_array!(dependencies.fetch("executables", []), "dependencies.executables")
      end

      def self.validate_permissions!(value)
        permissions = stringify_hash(value, "permissions")
        reject_unknown!(permissions, PERMISSION_KEYS, label: "permissions")
        %w[tools deny directories commands domains credentials].each do |key|
          string_array!(permissions.fetch(key, []), "permissions.#{key}")
        end
        %w[shell_justification network_justification credential_justification].each do |key|
          required_string!(permissions[key], "permissions.#{key}") if permissions.key?(key)
        end
      end

      def self.validate_files!(value)
        fail!("manifest.invalid_files", FILE_NAME, "files must be an array") unless value.is_a?(Array)
        paths = []
        value.each do |entry|
          file = stringify_hash(entry, "file entry")
          reject_unknown!(file, %w[path sha256 size], label: "file entry")
          validate_relative_path!(file["path"])
          fail!("manifest.self_hash", FILE_NAME, "manifest.json must not appear in its own file inventory") if file["path"] == FILE_NAME
          fail!("manifest.invalid_hash", file["path"], "file sha256 must be lowercase hexadecimal") unless file["sha256"].is_a?(String) && SHA256.match?(file["sha256"])
          fail!("manifest.invalid_size", file["path"], "file size must be a non-negative integer") unless file["size"].is_a?(Integer) && file["size"] >= 0
          paths << file["path"]
        end
        fail!("manifest.unsorted_files", FILE_NAME, "file inventory must be sorted by path") unless paths == paths.sort
        fail!("manifest.duplicate_file", FILE_NAME, "file inventory contains duplicate paths") unless paths.uniq == paths
        fail!("manifest.path_case_collision", FILE_NAME, "file inventory contains case-colliding paths") unless paths.map(&:downcase).uniq.length == paths.length
      end

      def self.validate_relative_path!(value)
        unless value.is_a?(String) && !value.empty? && value.valid_encoding? && !value.include?("\0")
          fail!("package.invalid_path", FILE_NAME, "package paths must be non-empty UTF-8 strings")
        end
        path = Pathname.new(value)
        if path.absolute? || value.start_with?("/") || value.include?("\\") || value.split("/").any? { |part| part.empty? || part == "." || part == ".." }
          fail!("package.path_escape", value, "package path must be normalized and remain inside the package")
        end
        value
      end

      def self.stringify_hash(value, label)
        fail!("manifest.invalid_type", FILE_NAME, "#{label} must be an object") unless value.is_a?(Hash)
        value.each_with_object({}) do |(key, child), out|
          fail!("manifest.invalid_key", FILE_NAME, "#{label} keys must be strings") unless key.is_a?(String) || key.is_a?(Symbol)
          out[key.to_s] = child
        end
      end

      def self.reject_unknown!(data, allowed, label:)
        unknown = data.keys.map(&:to_s) - allowed
        return if unknown.empty?

        fail!("manifest.unknown_key", FILE_NAME, "#{label} contains unsupported keys; upgrade Hive if this manifest is newer")
      end

      def self.required_string!(value, label)
        return if value.is_a?(String) && !value.strip.empty? && value.valid_encoding?

        fail!("manifest.invalid_value", FILE_NAME, "#{label} must be a non-empty UTF-8 string")
      end

      def self.string_array!(value, label)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.strip.empty? }
          fail!("manifest.invalid_value", FILE_NAME, "#{label} must be an array of non-empty strings")
        end
        if value.map(&:strip).uniq.length != value.length
          fail!("manifest.duplicate_value", FILE_NAME, "#{label} must not contain duplicate values")
        end
      end

      def self.default_permissions
        { "tools" => [], "deny" => [], "directories" => [], "commands" => [], "domains" => [], "credentials" => [] }
      end

      def self.fail!(rule, path, message)
        diagnostic = Diagnostic.new(rule_id: rule, severity: :error, path: path, message: message)
        raise PackageError, diagnostic
      end

      def initialize(data)
        self.class.validate_shape!(data)
        @data = Hive::WorkflowPackage::CanonicalJSON.normalize(data).freeze
        @bytes = Hive::WorkflowPackage::CanonicalJSON.generate(@data).freeze
        @digest = ::Digest::SHA256.hexdigest(@bytes).freeze
        freeze
      end

      def file_entries = data.fetch("files")
      def file_name = FILE_NAME
      def descriptor = data.fetch("descriptor")
      def summary = data.fetch("summary")
      def permissions = data.fetch("permissions")
    end
  end
end
