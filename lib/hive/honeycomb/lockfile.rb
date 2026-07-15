require "hive/atomic_file"
require "hive/honeycomb/manifest"

module Hive
  module Honeycomb
    LockEntry = Data.define(
      :source, :name, :sha, :version, :tag, :selector_kind, :selector_value,
      :digest, :files, :modes, :security
    ) do
      def self.from_verified(package)
        report = package.security_report
        new(
          source: package.pin.source,
          name: package.pin.name,
          sha: package.pin.sha,
          version: package.pin.version,
          tag: package.pin.tag,
          selector_kind: package.pin.selector_kind,
          selector_value: package.pin.selector_value,
          digest: package.pin.digest || package.manifest.package_digest,
          files: package.hashes,
          modes: package.modes,
          security: { "summary" => report.summary, "findings" => report.findings }
        )
      end

      def permissions_pointer
        "permissions: workflows/.honeycomb.lock#workflows.#{name}.security"
      end
    end

    class Lockfile
      ROOT_KEYS = %w[version workflows].freeze
      ENTRY_KEYS = %w[source name sha version tag requested_selector digest files modes security].freeze
      SELECTOR_KEYS = %w[kind value].freeze
      SELECTOR_KINDS = %w[latest version sha digest].freeze

      attr_reader :path

      def initialize(path)
        @path = File.expand_path(path)
      end

      def read
        return {} unless File.file?(path)
        raw = File.binread(path)
        root = mapping!(Honeycomb.safe_yaml_load(raw, label: "honeycomb lockfile", error_class: LockfileError), "lockfile")
        exact_keys!(root, ROOT_KEYS, "lockfile")
        raise LockfileError, "honeycomb lockfile version must be #{LOCK_VERSION}" unless root["version"] == LOCK_VERSION

        workflows = mapping!(root["workflows"], "lockfile workflows")
        workflows.keys.sort.to_h do |id|
          validate_name!(id)
          entry = parse_entry(id, workflows.fetch(id))
          [ id, entry ]
        end.freeze
      rescue ManifestError => e
        raise LockfileError, e.message
      rescue SystemCallError, IOError => e
        raise LockfileError, "honeycomb lockfile is unreadable: #{e.message}"
      end

      def write(entries)
        normalized = entries.keys.sort.to_h do |id|
          entry = entries.fetch(id)
          unless entry.is_a?(LockEntry) && id.to_s == entry.name
            raise LockfileError, "lock entry #{id.inspect} must be a matching LockEntry"
          end
          validated = parse_entry(id.to_s, serialize_entry(entry))
          [ id.to_s, serialize_entry(validated) ]
        end
        payload = { "version" => LOCK_VERSION, "workflows" => normalized }
        yaml = Psych.safe_dump(payload, aliases: false, line_width: -1)
        Hive::AtomicFile.write(path, yaml, mode: 0o644)
      end

      private

      def parse_entry(id, value)
        data = mapping!(value, "lock entry #{id.inspect}")
        exact_keys!(data, ENTRY_KEYS, "lock entry #{id.inspect}")
        validate_name!(data["name"])
        raise LockfileError, "lock entry key #{id.inspect} does not match name #{data['name'].inspect}" unless data["name"] == id
        raise LockfileError, "lock entry #{id.inspect} has an unsupported source" unless data["source"] == SOURCE

        sha = hex!(data["sha"], lengths: [ 40, 64 ], label: "lock entry #{id.inspect} sha")
        version = optional_string(data["version"], "lock entry #{id.inspect} version")
        if version && !SEMVER_RE.match?(version)
          raise LockfileError, "lock entry #{id.inspect} version must be exact SemVer"
        end
        tag = optional_string(data["tag"], "lock entry #{id.inspect} tag")
        digest = hex!(data["digest"], lengths: [ 64 ], label: "lock entry #{id.inspect} digest")
        selector = mapping!(data["requested_selector"], "lock entry #{id.inspect} requested_selector")
        exact_keys!(selector, SELECTOR_KEYS, "lock entry #{id.inspect} requested_selector")
        kind = selector["kind"]
        raise LockfileError, "lock entry #{id.inspect} has unknown selector kind #{kind.inspect}" unless SELECTOR_KINDS.include?(kind)
        selector_value = optional_string(selector["value"], "lock entry #{id.inspect} selector value")

        files = parse_inventory(data["files"], id, hashes: true)
        modes = parse_inventory(data["modes"], id, hashes: false)
        raise LockfileError, "lock entry #{id.inspect} modes must cover the file inventory" unless modes.keys == files.keys
        security = deep_data(mapping!(data["security"], "lock entry #{id.inspect} security"), "security")

        LockEntry.new(
          source: SOURCE, name: id, sha: sha, version: version, tag: tag,
          selector_kind: kind, selector_value: selector_value, digest: digest,
          files: files.freeze, modes: modes.freeze, security: security.freeze
        )
      end

      def parse_inventory(value, id, hashes:)
        inventory = mapping!(value, "lock entry #{id.inspect} #{hashes ? 'files' : 'modes'}")
        normalized = {}
        inventory.each do |raw_path, raw_value|
          path = Manifest.normalize_path(raw_path)
          raise LockfileError, "lock entry #{id.inspect} contains duplicate normalized path #{path.inspect}" if normalized.key?(path)
          value = if hashes
            hex!(raw_value, lengths: [ 64 ], label: "lock entry #{id.inspect} file #{path.inspect}")
          else
            unless %w[100644 100755].include?(raw_value)
              raise LockfileError, "lock entry #{id.inspect} mode for #{path.inspect} is invalid"
            end
            raw_value
          end
          normalized[path] = value
        end
        normalized.sort.to_h
      end

      def serialize_entry(entry)
        {
          "source" => entry.source,
          "name" => entry.name,
          "sha" => entry.sha,
          "version" => entry.version,
          "tag" => entry.tag,
          "requested_selector" => { "kind" => entry.selector_kind, "value" => entry.selector_value },
          "digest" => entry.digest,
          "files" => entry.files.sort.to_h,
          "modes" => entry.modes.sort.to_h,
          "security" => deep_data(entry.security, "security")
        }
      end

      def mapping!(value, label)
        raise LockfileError, "#{label} must be a mapping" unless value.is_a?(Hash)
        value.each_key do |key|
          raise LockfileError, "#{label} contains non-string key #{key.inspect}" unless key.is_a?(String)
        end
        value
      end

      def exact_keys!(data, keys, label)
        missing = keys - data.keys
        unknown = data.keys - keys
        raise LockfileError, "#{label} missing key(s) #{missing.inspect}" unless missing.empty?
        raise LockfileError, "#{label} contains unknown key(s) #{unknown.inspect}" unless unknown.empty?
      end

      def validate_name!(name)
        return if name.is_a?(String) && REFERENCE_NAME_RE.match?(name)
        raise LockfileError, "invalid lock workflow name #{name.inspect}"
      end

      def optional_string(value, label)
        return nil if value.nil?
        return value if value.is_a?(String) && !value.empty?
        raise LockfileError, "#{label} must be a non-empty string or null"
      end

      def hex!(value, lengths:, label:)
        unless value.is_a?(String) && lengths.include?(value.length) && value.match?(/\A[0-9a-f]+\z/)
          raise LockfileError, "#{label} must be lowercase hex"
        end
        value
      end

      def deep_data(value, label)
        case value
        when Hash
          value.keys.sort.to_h do |key|
            raise LockfileError, "#{label} contains non-string key #{key.inspect}" unless key.is_a?(String)
            [ key, deep_data(value.fetch(key), label) ]
          end
        when Array
          value.map { |item| deep_data(item, label) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          raise LockfileError, "#{label} contains unsupported value #{value.inspect}"
        end
      end
    end
  end
end
