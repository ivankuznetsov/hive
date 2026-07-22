require "digest"
require "json"
require "hive/stringify_keys"
require "hive/module_package/manifest"
require "hive/workflow_package/canonical_json"

module Hive
  module ModulePackage
    class Configuration
      SCHEMA_VERSION = 1
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/
      SHA256 = Manifest::SHA256

      attr_reader :data, :bytes, :digest

      def self.build(descriptor, generation:, settings:, hooks:, grants:)
        settings = stringify_hash(settings, "module settings")
        hooks = stringify_hash(hooks, "module hooks")
        grants = stringify_hash(grants, "module grants")
        setting_specs = descriptor.settings.to_h { |spec| [ spec.fetch("name"), spec ] }
        hook_specs = descriptor.hooks.to_h { |spec| [ spec.fetch("id"), spec ] }
        require_exact_keys!(settings, setting_specs.keys, "setting choices")
        require_exact_keys!(hooks, hook_specs.keys, "hook choices")
        normalized_settings = setting_specs.to_h do |name, spec|
          [ name, normalize_setting(name, settings.fetch(name), spec) ]
        end
        hooks.each do |name, enabled|
          raise Hive::ConfigError, "module hook #{name.inspect} choice must be boolean" unless [ true, false ].include?(enabled)
        end
        normalized_grants = normalize_grants(descriptor.permissions, grants)
        generation_data = normalize_generation(generation)
        contract = {
          "hooks" => descriptor.hooks,
          "settings" => descriptor.settings,
          "permissions" => descriptor.permissions
        }
        data = {
          "schema_version" => SCHEMA_VERSION,
          "generation" => generation_data,
          "contract_digest" => ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(contract)),
          "settings" => normalized_settings.sort.to_h,
          "hooks" => hooks.sort.to_h,
          "grants" => normalized_grants,
          "permission_digest" => ::Digest::SHA256.hexdigest(
            Hive::WorkflowPackage::CanonicalJSON.generate(descriptor.permissions)
          ),
          "contract" => contract
        }
        new(data)
      end

      def self.load(bytes)
        data = JSON.parse(bytes)
        unless bytes == Hive::WorkflowPackage::CanonicalJSON.generate(data)
          raise Hive::ConfigError, "module configuration is not canonical JSON"
        end
        new(data)
      rescue JSON::ParserError, EncodingError
        raise Hive::ConfigError, "module configuration is malformed"
      end

      def initialize(data)
        @data = Hive::StringifyKeys.call(data)
        validate!
        @bytes = Hive::WorkflowPackage::CanonicalJSON.generate(@data).freeze
        @digest = ::Digest::SHA256.hexdigest(@bytes).freeze
        deep_freeze(@data)
        freeze
      end

      def settings = data.fetch("settings")
      def hooks = data.fetch("hooks")
      def grants = data.fetch("grants")
      def generation = data.fetch("generation")
      def contract = data.fetch("contract")

      class << self
        private

        def stringify_hash(value, label)
          raise Hive::ConfigError, "#{label} must be a map" unless value.is_a?(Hash)
          value.to_h { |key, child| [ key.to_s, child ] }
        end

        def require_exact_keys!(values, expected, label)
          return if values.keys.sort == expected.sort
          missing = expected - values.keys
          unknown = values.keys - expected
          detail = []
          detail << "missing #{missing.sort.join(', ')}" if missing.any?
          detail << "unknown #{unknown.sort.join(', ')}" if unknown.any?
          raise Hive::ConfigError, "module #{label} are incomplete (#{detail.join('; ')})"
        end

        def normalize_setting(name, value, spec)
          if value.nil?
            raise Hive::ConfigError, "module setting #{name.inspect} is required" if spec.fetch("required")
            return nil
          end
          valid = case spec.fetch("type")
          when "boolean" then [ true, false ].include?(value)
          when "integer" then value.is_a?(Integer)
          when "number" then value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
          when "enum" then spec.fetch("values").include?(value)
          when "secret" then value.is_a?(String) && ENV_NAME.match?(value)
          when "string" then value.is_a?(String) && value.valid_encoding?
          else false
          end
          raise Hive::ConfigError, "module setting #{name.inspect} has an invalid value" unless valid
          value
        end

        def normalize_grants(requested, grants)
          require_exact_keys!(grants, Manifest::PERMISSION_KEYS, "grant choices")
          normalized = { "repository_write" => grants.fetch("repository_write") }
          unless [ true, false ].include?(normalized["repository_write"])
            raise Hive::ConfigError, "module repository_write grant must be boolean"
          end
          Manifest::PERMISSION_KEYS.grep_v("repository_write").each do |key|
            value = grants.fetch(key)
            unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) } && value.uniq == value
              raise Hive::ConfigError, "module grant #{key.inspect} must be a unique string set"
            end
            normalized[key] = value.sort
          end
          requested = requested.transform_keys(&:to_s)
          if requested.fetch("repository_write") && !normalized.fetch("repository_write")
            raise Hive::ConfigError, "module repository write permission was not granted"
          end
          if !requested.fetch("repository_write") && normalized.fetch("repository_write")
            raise Hive::ConfigError, "module repository write grant exceeds the reviewed manifest"
          end
          Manifest::PERMISSION_KEYS.grep_v("repository_write").each do |key|
            requested_values = requested.fetch(key).sort
            granted_values = normalized.fetch(key)
            missing = requested_values - granted_values
            excess = granted_values - requested_values
            raise Hive::ConfigError, "module permission #{key} was not completely granted" if missing.any?
            raise Hive::ConfigError, "module grant #{key} exceeds the reviewed manifest" if excess.any?
          end
          normalized.sort.to_h
        end

        def normalize_generation(generation)
          values = {
            "name" => generation.name.to_s,
            "version" => generation.version.to_s,
            "catalog_commit" => generation.catalog_commit.to_s,
            "source_commit" => generation.source_commit.to_s,
            "manifest_digest" => generation.manifest_digest.to_s
          }
          unless Manifest::NAME.match?(values["name"]) && Manifest::SEMVER.match?(values["version"]) &&
                 Manifest::REVISION.match?(values["catalog_commit"]) && Manifest::REVISION.match?(values["source_commit"]) &&
                 SHA256.match?(values["manifest_digest"])
            raise Hive::ConfigError, "module configuration generation is malformed"
          end
          values
        end
      end

      private

      def validate!
        expected = %w[contract contract_digest generation grants hooks permission_digest schema_version settings]
        unless data.is_a?(Hash) && data.keys.sort == expected && data["schema_version"] == SCHEMA_VERSION
          raise Hive::ConfigError, "module configuration has an unsupported shape"
        end
        generation = data.fetch("generation")
        unless generation.is_a?(Hash) && generation.keys.sort == %w[catalog_commit manifest_digest name source_commit version] &&
               Manifest::NAME.match?(generation["name"].to_s) && Manifest::SEMVER.match?(generation["version"].to_s) &&
               Manifest::REVISION.match?(generation["catalog_commit"].to_s) && Manifest::REVISION.match?(generation["source_commit"].to_s) &&
               SHA256.match?(generation["manifest_digest"].to_s)
          raise Hive::ConfigError, "module configuration generation is malformed"
        end
        unless SHA256.match?(data["contract_digest"].to_s) && SHA256.match?(data["permission_digest"].to_s) &&
               data["settings"].is_a?(Hash) && data["hooks"].is_a?(Hash) && data["grants"].is_a?(Hash) && data["contract"].is_a?(Hash)
          raise Hive::ConfigError, "module configuration content is malformed"
        end
        contract_digest = ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(data.fetch("contract")))
        permission_digest = ::Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalJSON.generate(data.dig("contract", "permissions"))
        )
        unless contract_digest == data["contract_digest"] && permission_digest == data["permission_digest"]
          raise Hive::ConfigError, "module configuration contract digest is tampered"
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, child| key.freeze; deep_freeze(child) }.freeze
        when Array then value.each { |child| deep_freeze(child) }.freeze
        else value.freeze
        end
      end
    end
  end
end
