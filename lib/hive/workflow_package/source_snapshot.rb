require "fileutils"
require "pathname"
require "yaml"
require "hive/workflow_package/authoring_metadata"
require "hive/workflow_package/registry_manifest"

module Hive
  module WorkflowPackage
    class SourceSnapshot
      MAX_FILE_BYTES = 1024 * 1024
      MAX_TOTAL_BYTES = 10 * 1024 * 1024
      MAX_FILES = 1000
      SKILL_NAME = /\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]{0,127}\z/

      FileRecord = Data.define(:path, :bytes, :mode, :source)
      Snapshot = Data.define(:name, :descriptor, :files, :external_skills)

      def self.capture(name:, workflows_dir:, descriptor_path:, authored_dir:, metadata:)
        new(
          name: name, workflows_dir: workflows_dir, descriptor_path: descriptor_path,
          authored_dir: authored_dir, metadata: metadata
        ).capture
      end

      def initialize(name:, workflows_dir:, descriptor_path:, authored_dir:, metadata:)
        @name = name.to_s
        @workflows_dir = File.expand_path(workflows_dir)
        @descriptor_path = File.expand_path(descriptor_path)
        @authored_dir = File.expand_path(authored_dir)
        @metadata = metadata
        @total_bytes = 0
      end

      def capture
        validate_roots!
        descriptor_record = read_record(@descriptor_path, package_path: "workflow.yml")
        descriptor = AuthoringMetadata.parse_yaml_map(descriptor_record.bytes, label: "workflow descriptor")
        unless descriptor["id"] == @name
          raise Hive::ConfigError, "workflow descriptor id must exactly match publish id #{@name.inspect}"
        end

        instructions = {}
        external_skills = []
        rewritten = transform_descriptor(descriptor) do |key, value|
          case key
          when "instruction"
            source, relative = resolve_owned_path(value, kind: "instruction")
            packaged = normalize_path(File.join("instructions", relative), label: "instruction")
            add_unique!(instructions, packaged, source)
            packaged
          when "skill"
            validate_skill!(value)
            external_skills << value
            value
          else
            value
          end
        end
        raise Hive::ConfigError, "workflow publish requires at least one referenced local instruction" if instructions.empty?

        files = {
          "workflow.yml" => FileRecord.new(
            path: "workflow.yml", bytes: YAML.dump(rewritten), mode: 0o644, source: @descriptor_path
          ),
          "README.md" => read_record(File.join(@authored_dir, "README.md"), package_path: "README.md")
        }
        instructions.sort.each do |package_path, source|
          files[package_path] = read_record(source, package_path: package_path)
        end
        Array(@metadata.assets).each do |relative|
          normalized = normalize_path(relative, label: "asset")
          raise Hive::ConfigError, "declared asset collides with generated package path" if files.key?(normalized)
          source, = resolve_owned_path(relative, kind: "asset", base: @authored_dir)
          files[normalized] = read_record(source, package_path: normalized, preserve_executable: true)
        end
        raise Hive::ConfigError, "workflow package exceeds file-count limit" if files.length > MAX_FILES

        Snapshot.new(
          name: @name, descriptor: deep_freeze(rewritten), files: files.sort.to_h.freeze,
          external_skills: external_skills.sort.uniq.freeze
        ).freeze
      end

      private

      def validate_roots!
        [ [ @workflows_dir, "workflows root" ], [ @authored_dir, "authored workflow root" ] ].each do |path, label|
          stat = File.lstat(path)
          unless stat.directory? && !stat.symlink?
            raise Hive::ConfigError, "#{label} must be a real directory, not a symlink"
          end
        end
        prefix = @workflows_dir + File::SEPARATOR
        unless @descriptor_path.start_with?(prefix) && @authored_dir.start_with?(prefix)
          raise Hive::ConfigError, "workflow publication inputs must stay inside the owned workflows root"
        end
      rescue Errno::ENOENT, Errno::EACCES, IOError
        raise Hive::ConfigError, "workflow publication source roots are missing or unreadable"
      end

      def transform_descriptor(value, &block)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), out|
            out[key] = child.is_a?(Hash) || child.is_a?(Array) ? transform_descriptor(child, &block) : block.call(key, child)
          end
        when Array
          value.map { |child| transform_descriptor(child, &block) }
        else
          value
        end
      end

      def resolve_owned_path(value, kind:, base: @workflows_dir)
        unless value.is_a?(String) && !value.strip.empty? && !value.include?("\\") && !value.include?("\0")
          raise Hive::ConfigError, "workflow #{kind} reference must be a non-empty portable path"
        end
        source = File.expand_path(value, base)
        prefix = @authored_dir + File::SEPARATOR
        unless source.start_with?(prefix)
          raise Hive::ConfigError, "workflow #{kind} must stay beneath the authored workflow root"
        end
        relative = Pathname.new(source).relative_path_from(Pathname.new(@authored_dir)).to_s
        [ source, normalize_path(relative, label: kind) ]
      end

      def normalize_path(path, label:)
        normalized = path.to_s.unicode_normalize(:nfc)
        RegistryManifest.validate_relative_path!(normalized)
        normalized
      rescue PackageError
        raise Hive::ConfigError, "workflow #{label} path is not a normalized safe relative path"
      end

      def add_unique!(values, package_path, source)
        if values.key?(package_path) && values.fetch(package_path) != source
          raise Hive::ConfigError, "workflow input paths collide after Unicode normalization"
        end
        values[package_path] = source
      end

      def validate_skill!(value)
        unless value.is_a?(String) && SKILL_NAME.match?(value)
          raise Hive::ConfigError, "workflow external skill dependency is malformed"
        end
      end

      def read_record(source, package_path:, preserve_executable: false)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        file = File.open(source, flags)
        before = file.stat
        unless before.file? && before.nlink == 1 && before.size <= MAX_FILE_BYTES
          raise Hive::ConfigError, "workflow package input #{package_path.inspect} must be a bounded independent regular file"
        end
        bytes = file.read(MAX_FILE_BYTES + 1)
        after = file.stat
        current = File.lstat(source)
        identity = %i[dev ino size mtime ctime].all? { |field| before.public_send(field) == after.public_send(field) } &&
                   before.dev == current.dev && before.ino == current.ino && !current.symlink?
        unless identity && bytes.bytesize <= MAX_FILE_BYTES
          raise Hive::ConfigError, "workflow package input #{package_path.inspect} changed while being read"
        end
        @total_bytes += bytes.bytesize
        raise Hive::ConfigError, "workflow package inputs exceed total-byte limit" if @total_bytes > MAX_TOTAL_BYTES
        mode = preserve_executable && (before.mode & 0o111).positive? ? 0o755 : 0o644
        FileRecord.new(path: package_path, bytes: bytes.freeze, mode: mode, source: source).freeze
      rescue Errno::ELOOP, Errno::ENOENT, Errno::EACCES, IOError
        raise Hive::ConfigError, "workflow package input #{package_path.inspect} is missing, linked, or unreadable"
      ensure
        file&.close
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end
    end
  end
end
