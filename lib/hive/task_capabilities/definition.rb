require "digest"
require "pathname"
require "hive/agent_profiles"
require "hive/permission_scope"
require "hive/stringify_keys"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/runtime_policy"
require "hive/secret_patterns"
require "shellwords"

module Hive
  module TaskCapabilities
    # One normalized attachment contract, shared by descriptors and projects.
    class Definition
      ID = /\A[a-z0-9][a-z0-9-]*\z/
      KEYS = %w[id kind stages skill instruction instruction_digest actor permissions targets budget_usd timeout_sec checks depends_on conflicts before after].freeze
      ACTOR_KEYS = %w[profile provider model effort provider_account launch_binding].freeze
      CHECK_KEYS = %w[id kind claim command provider depends_on].freeze
      CHECK_KINDS = %w[behavior source_review dependency_review].freeze

      attr_reader :data, :source, :instruction_path

      def initialize(value, stages:, source:, package_root: nil)
        @source = source.to_s.freeze
        @data = self.class.mapping(value, keys: KEYS, label: source)
        self.class.identifier(@data["id"], label: "#{source} capability id")
        label = "#{source} capability #{@data['id'].inspect}"
        unless %w[guidance verification].include?(@data["kind"])
          raise Hive::ConfigError, "#{label} kind must be guidance or verification"
        end
        bindings = self.class.strings(@data["stages"], label: "#{label} stages", nonempty: true)
        unknown = bindings - stages.map(&:name)
        raise Hive::ConfigError, "#{label} unknown stage bindings: #{unknown.join(', ')}" unless unknown.empty?
        @data["stages"] = bindings.sort_by { |name| stages.index { |stage| stage.name == name } }
        %w[skill instruction].each { |key| self.class.text(@data[key], label: "#{label} #{key}") if @data.key?(key) }
        if @data.key?("skill") && @data.key?("instruction")
          raise Hive::ConfigError, "#{label} must declare at most one of skill or instruction"
        end
        if @data["instruction"]
          path = File.expand_path(@data["instruction"], File.dirname(source))
          if package_root && !path.start_with?(File.expand_path(package_root) + File::SEPARATOR)
            raise Hive::ConfigError, "#{label} instruction must remain inside the package"
          end
          raise Hive::ConfigError, "#{label} instruction must reference a readable file" unless File.file?(path) && File.readable?(path)
          digest = ::Digest::SHA256.file(path).hexdigest
          if @data.key?("instruction_digest") && @data["instruction_digest"] != digest
            raise Hive::ConfigError, "#{label} instruction digest does not match the referenced file"
          end
          @instruction_path = path.freeze
          @data["instruction"] = Pathname.new(path).relative_path_from(Pathname.new(File.expand_path(File.dirname(source)))).to_s
          @data["instruction_digest"] = digest
        elsif @data.key?("instruction_digest")
          raise Hive::ConfigError, "#{label} instruction_digest requires an instruction"
        end
        @data["actor"] = self.class.actor(@data["actor"], label: label) if @data.key?("actor")
        if @data.key?("permissions")
          self.class.permissions(@data["permissions"], actor: @data["actor"], label: label)
        end
        @data["targets"] = self.class.targets(@data.fetch("targets", []), label: label)
        %w[budget_usd timeout_sec].each do |key|
          self.class.positive(@data[key], label: "#{label} #{key}", integer: key == "timeout_sec") if @data.key?(key)
        end
        %w[depends_on conflicts before after].each do |key|
          @data[key] = self.class.strings(@data.fetch(key, []), label: "#{label} #{key}")
          @data[key].each { |id| self.class.identifier(id, label: "#{label} #{key}") }
        end
        @data["checks"] = parse_checks(@data.fetch("checks", []), label)
        self.class.deep_freeze(@data)
        freeze
      end

      def id = data.fetch("id")
      def kind = data.fetch("kind")
      def stages = data.fetch("stages")
      def checks = data.fetch("checks")
      def to_h = data
      def fingerprint = ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(data))

      def self.mapping(value, keys:, label:)
        raise Hive::ConfigError, "#{label} must be a map" unless value.is_a?(Hash)
        result = Hive::StringifyKeys.call(value)
        unknown = result.keys - keys
        raise Hive::ConfigError, "#{label} unknown fields: #{unknown.sort.join(', ')}" unless unknown.empty?
        result
      end

      def self.text(value, label:)
        unless value.is_a?(String) && !value.strip.empty? && !value.include?("\0")
          raise Hive::ConfigError, "#{label} must be a nonempty string"
        end
        value
      end

      def self.identifier(value, label:)
        text(value, label: label)
        raise Hive::ConfigError, "#{label} must be a lowercase capability/check ID" unless ID.match?(value)
        value
      end

      def self.strings(value, label:, nonempty: false)
        unless value.is_a?(Array) && (!nonempty || !value.empty?)
          raise Hive::ConfigError, "#{label} must be #{nonempty ? 'a nonempty' : 'an'} array"
        end
        value.each { |entry| text(entry, label: label) }
        raise Hive::ConfigError, "#{label} contains duplicates" unless value.uniq.length == value.length
        value.dup
      end

      def self.positive(value, label:, integer: false)
        unless value.is_a?(Numeric) && value.finite? && value.positive? && (!integer || value.is_a?(Integer))
          raise Hive::ConfigError, "#{label} must be a positive finite #{integer ? 'integer' : 'number'}"
        end
        value
      end

      def self.actor(value, label:)
        result = mapping(value, keys: ACTOR_KEYS, label: "#{label} actor")
        %w[profile provider model].each { |key| text(result[key], label: "#{label} actor #{key}") }
        profile = Hive::AgentProfiles.lookup(result["profile"])
        if !profile.model_argument_builder || (result.key?("effort") && !profile.effort_argument_builder)
          raise Hive::ConfigError, "#{label} actor profile cannot pin the requested identity"
        end
        text(result["effort"], label: "#{label} actor effort") if result.key?("effort")
        %w[provider_account launch_binding].each do |key|
          next unless result.key?(key)
          text(result[key], label: "#{label} actor #{key}")
          unless result[key].match?(/\A[a-z][a-z0-9_-]{0,63}\z/)
            raise Hive::ConfigError, "#{label} actor #{key} must be an exact lowercase account/binding reference"
          end
        end
        result
      end

      def self.permissions(value, actor:, label:)
        if value.is_a?(Hash) && !value.key?("preset") && !value.key?(:preset)
          profile = actor && Hive::AgentProfiles.lookup(actor.fetch("profile"))
          Hive::WorkflowPackage::RuntimePolicy.validate_spec!(value, profile: profile)
        else
          Hive::PermissionScope.validate!(value, stage: label)
        end
      rescue Hive::ConfigError => e
        raise Hive::ConfigError, "#{label}: #{e.message}"
      end

      def self.targets(value, label:)
        strings(value, label: "#{label} targets").each do |target|
          if target.start_with?("/", "~") || target.include?("\\") || target.include?(":") ||
             target.split("/").any? { |part| [ "", ".", ".." ].include?(part) } || !target.match?(%r{\A[a-zA-Z0-9_./-]+\z})
            raise Hive::ConfigError, "#{label} targets must be exact task-relative references; external targets are unsupported"
          end
        end
      end

      def self.deep_freeze(value)
        case value
        when Hash then value.each_value { |child| deep_freeze(child) }
        when Array then value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end

      private

      def parse_checks(value, label)
        raise Hive::ConfigError, "#{label} checks must be an array" unless value.is_a?(Array)
        raise Hive::ConfigError, "#{label} guidance cannot declare verification checks" if kind == "guidance" && !value.empty?
        checks = value.map do |entry|
          check = self.class.mapping(entry, keys: CHECK_KEYS, label: "#{label} check")
          self.class.identifier(check["id"], label: "#{label} check id")
          unless CHECK_KINDS.include?(check["kind"])
            raise Hive::ConfigError, "#{label} check #{check['id'].inspect} has unsupported kind"
          end
          self.class.text(check["claim"], label: "#{label} check claim")
          %w[command provider].each { |key| self.class.text(check[key], label: "#{label} check #{key}") if check.key?(key) }
          if check["command"]
            begin
              unless !Shellwords.split(check["command"]).empty? && Hive::SecretPatterns.redact(check["command"]) == check["command"]
                raise Hive::ConfigError, "#{label} check command must be a non-secret executable reference"
              end
            rescue ArgumentError
              raise Hive::ConfigError, "#{label} check command has invalid quoting"
            end
          end
          check["depends_on"] = self.class.strings(check.fetch("depends_on", []), label: "#{label} check dependencies")
          check
        end
        ids = checks.map { |check| check.fetch("id") }
        raise Hive::ConfigError, "#{label} duplicate check IDs" unless ids.uniq.length == ids.length
        checks.each do |check|
          unless (check.fetch("depends_on") - ids).empty?
            raise Hive::ConfigError, "#{label} check #{check['id'].inspect} has unknown check dependencies"
          end
        end
        self.class.acyclic!(checks.to_h { |check| [ check.fetch("id"), check.fetch("depends_on") ] }, label: "#{label} check dependencies")
        checks
      end

      public

      def self.acyclic!(edges, label:)
        remaining = edges.transform_values(&:dup)
        until remaining.empty?
          ready = remaining.select { |_id, deps| deps.empty? }.keys
          raise Hive::ConfigError, "#{label} contains a cycle or impossible order" if ready.empty?
          ready.each { |id| remaining.delete(id) }
          remaining.each_value { |deps| deps.reject! { |id| ready.include?(id) } }
        end
        true
      end
    end
  end
end
