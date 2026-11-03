require "hive/task_capabilities/catalog"

module Hive
  module TaskCapabilities
    class Policy
      SIGNAL_TYPES = %w[task_label task_text repository_path changed_path].freeze
      APPROVAL_KEYS = %w[capability actor permissions targets budget_usd timeout_sec].freeze
      attr_reader :data, :approvals

      def initialize(value, catalog:, approvals: {}, source: "project task_capabilities")
        @catalog = catalog
        @source = source
        @data = Definition.mapping(value, keys: %w[required auto_select], label: "#{source} policy")
        @data["required"] = Definition.strings(@data.fetch("required", []), label: "#{source} required")
        @data["required"].each { |id| catalog.fetch(id) }
        @data["auto_select"] = parse_rules(@data.fetch("auto_select", []))
        @approvals = parse_approvals(approvals)
        Definition.deep_freeze(@data)
        Definition.deep_freeze(@approvals)
        freeze
      end

      def required?(id) = data.fetch("required").include?(id)
      def to_h = Definition.deep_freeze({ "policy" => data, "approvals" => approvals })

      def matches(task_labels: [], task_text: "", repository_paths: [], changed_paths: [])
        values = { "task_label" => task_labels, "task_text" => [ task_text ],
                   "repository_path" => repository_paths, "changed_path" => changed_paths }
        data.fetch("auto_select").filter_map do |rule|
          matched = rule.fetch("signals").filter_map do |signal|
            type, value = signal.values_at("type", "value")
            match = values.fetch(type).find do |candidate|
              case type
              when "task_text" then candidate.downcase.include?(value.downcase)
              when "task_label" then candidate == value
              else File.fnmatch?(value, candidate, File::FNM_PATHNAME | File::FNM_EXTGLOB)
              end
            end
            signal.merge("matched" => type == "task_text" ? value : match) if match
          end
          { "capability" => rule.fetch("capability"), "signals" => matched } unless matched.empty?
        end
      end

      private

      def parse_rules(value)
        raise Hive::ConfigError, "#{@source} auto_select must be an array" unless value.is_a?(Array)
        value.map do |raw|
          rule = Definition.mapping(raw, keys: %w[capability signals], label: "#{@source} auto_select rule")
          id = rule["capability"]
          @catalog.fetch(id)
          raise Hive::ConfigError, "#{@source} automatic selection is only admitted for UI guidance" unless id == "ui"
          signals = rule["signals"]
          unless signals.is_a?(Array) && !signals.empty?
            raise Hive::ConfigError, "#{@source} auto_select signals must be a nonempty array"
          end
          rule["signals"] = signals.map do |raw_signal|
            signal = Definition.mapping(raw_signal, keys: %w[type value], label: "#{@source} selection signal")
            unless SIGNAL_TYPES.include?(signal["type"])
              raise Hive::ConfigError, "#{@source} selection signal type must be one of #{SIGNAL_TYPES.join(', ')}"
            end
            Definition.text(signal["value"], label: "#{@source} selection signal value")
            signal
          end
          rule
        end
      end

      def parse_approvals(value)
        raise Hive::ConfigError, "#{@source} approvals must be a map" unless value.is_a?(Hash)
        value.each_with_object({}) do |(reference, raw), result|
          Definition.identifier(reference, label: "#{@source} approval reference")
          label = "#{@source} approval #{reference.inspect}"
          approval = Definition.mapping(raw, keys: APPROVAL_KEYS, label: label)
          definition = @catalog.fetch(approval["capability"])
          raise Hive::ConfigError, "#{label} must name a verification capability" unless definition.kind == "verification"
          approval["actor"] = Definition.actor(approval["actor"], label: label)
          permissions = approval["permissions"]
          unless permissions.is_a?(Hash) && !permissions.key?("preset")
            raise Hive::ConfigError, "#{label} requires an enforceable tools/commands/domains permission envelope"
          end
          Definition.permissions(permissions, actor: approval["actor"], label: label)
          unless (permissions.fetch("domains", []) - %w[localhost 127.0.0.1]).empty?
            raise Hive::ConfigError, "#{label} external scanning domains are unsupported; use isolated local targets"
          end
          approval["targets"] = Definition.targets(approval["targets"], label: label)
          raise Hive::ConfigError, "#{label} requires at least one local target reference" if approval["targets"].empty?
          Definition.positive(approval["budget_usd"], label: "#{label} budget_usd")
          Definition.positive(approval["timeout_sec"], label: "#{label} timeout_sec", integer: true)
          result[reference] = approval
        end
      end
    end
  end
end
