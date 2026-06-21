require "yaml"
require "hive/permission_scope"
require "hive/workflow"

module Hive
  module Workflows
    module DescriptorParser
      SAFE_SLUG = /\A[a-z0-9][a-z0-9-]*\z/
      TOP_LEVEL_KEYS = %w[id stages].freeze
      STAGE_KEYS = %w[
        name
        kind
        state_file
        advance_verb
        skill
        instruction
        permissions
      ].freeze

      module_function

      def parse_file(path)
        parsed = YAML.safe_load(File.read(path))
        parse_hash(parsed, path: path)
      rescue Psych::Exception => e
        raise descriptor_error(path, "is not valid YAML: #{e.message}")
      rescue SystemCallError, IOError => e
        raise descriptor_error(path, "is not readable: #{e.message}")
      end

      def parse_hash(data, path:)
        descriptor = stringify_hash(data, path: path, label: "descriptor")
        reject_unknown_keys!(descriptor, TOP_LEVEL_KEYS, path: path, label: "descriptor")
        id = parse_id(descriptor["id"], path: path)
        validate_filename_id!(id, path)
        stages = parse_stages(descriptor["stages"], id: id, path: path)

        Hive::Workflow.new(id: id.to_sym, stages: stages)
      rescue ArgumentError => e
        raise descriptor_error(path, e.message)
      end

      def parse_id(value, path:)
        id = required_string(value, path: path, label: "id")
        return id if SAFE_SLUG.match?(id)

        raise descriptor_error(path, "id #{id.inspect} must match #{SAFE_SLUG.source}")
      end

      def validate_filename_id!(id, path)
        expected = File.basename(path, File.extname(path))
        return if id == expected

        raise descriptor_error(path, "id #{id.inspect} must match filename #{expected.inspect}")
      end

      def parse_stages(data, id:, path:)
        unless data.is_a?(Array)
          raise descriptor_error(path, "stages must be an array")
        end

        data.each_with_index.map do |stage_data, offset|
          parse_stage(stage_data, id: id, path: path, index: offset + 1)
        end
      end

      def parse_stage(data, id:, path:, index:)
        label = "stage #{index}"
        stage = stringify_hash(data, path: path, label: label)
        reject_unknown_keys!(stage, STAGE_KEYS, path: path, label: label)
        name = parse_stage_name(stage["name"], path: path, label: label)
        kind = parse_kind(stage["kind"], path: path, label: label)
        skill = optional_string(stage["skill"], path: path, label: "#{label} skill")
        instruction = parse_instruction(stage["instruction"], path: path, label: label)
        permissions = parse_permissions(stage, id: id, stage_name: name, path: path, label: label)
        validate_agent_instruction!(skill: skill, instruction: instruction, path: path, label: label) if kind == :agent

        Hive::Workflow::Stage.new(
          name: name,
          index: index,
          state_file: required_string(stage["state_file"], path: path, label: "#{label} state_file"),
          advance_verb: parse_advance_verb(stage, name: name, index: index, path: path, label: label),
          kind: kind,
          skill: skill,
          instruction: instruction,
          permissions: permissions
        )
      end

      def parse_stage_name(value, path:, label:)
        name = required_string(value, path: path, label: "#{label} name")
        return name if SAFE_SLUG.match?(name)

        raise descriptor_error(path, "#{label} name #{name.inspect} must match #{SAFE_SLUG.source}")
      end

      def parse_kind(value, path:, label:)
        raw = required_string(value, path: path, label: "#{label} kind")
        case raw
        when "agent" then :agent
        when "terminal" then :inert
        when "council"
          raise descriptor_error(path, "#{label} kind 'council' is not yet supported (reserved for a future release)")
        else
          raise descriptor_error(path, "#{label} kind #{raw.inspect} must be agent or terminal")
        end
      end

      def parse_instruction(value, path:, label:)
        raw = optional_string(value, path: path, label: "#{label} instruction")
        return nil if raw.nil?

        resolved = File.expand_path(raw, File.dirname(path))
        return resolved if File.file?(resolved) && File.readable?(resolved)

        raise descriptor_error(path, "#{label} instruction #{raw.inspect} must reference a readable file (#{resolved})")
      end

      def parse_permissions(stage, id:, stage_name:, path:, label:)
        return nil unless stage.key?("permissions")

        value = stage["permissions"]
        Hive::PermissionScope.validate!(value, stage: "#{id}.#{stage_name}")
        deep_freeze(value)
      rescue Hive::ConfigError => e
        raise descriptor_error(path, "#{label} #{e.message}")
      end

      def parse_advance_verb(stage, name:, index:, path:, label:)
        return nil if index == 1 && !stage.key?("advance_verb")

        verb_name =
          if stage.key?("advance_verb")
            optional_string(stage["advance_verb"], path: path, label: "#{label} advance_verb")
          else
            name
          end
        return nil if verb_name.nil?

        Hive::Workflow::AdvanceVerb.new(name: verb_name)
      end

      def validate_agent_instruction!(skill:, instruction:, path:, label:)
        return if skill.nil? ^ instruction.nil?

        raise descriptor_error(path, "#{label} agent stages must declare exactly one of skill or instruction")
      end

      def stringify_hash(data, path:, label:)
        unless data.is_a?(Hash)
          raise descriptor_error(path, "#{label} must be a map")
        end

        data.each_with_object({}) do |(key, value), out|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise descriptor_error(path, "#{label} contains non-string key #{key.inspect}")
          end

          out[key.to_s] = value
        end
      end

      def reject_unknown_keys!(data, allowed, path:, label:)
        unknown = data.keys - allowed
        return if unknown.empty?

        raise descriptor_error(path, "#{label} contains unknown key(s) #{unknown.inspect}")
      end

      def required_string(value, path:, label:)
        string = optional_string(value, path: path, label: label)
        return string unless string.nil?

        raise descriptor_error(path, "#{label} must be a non-empty string")
      end

      def optional_string(value, path:, label:)
        return nil if value.nil?
        return value.strip if value.is_a?(String) && !value.strip.empty?

        raise descriptor_error(path, "#{label} must be a non-empty string")
      end

      def deep_freeze(value)
        case value
        when Hash
          value.transform_values { |child| deep_freeze(child) }.freeze
        when Array
          value.map { |child| deep_freeze(child) }.freeze
        else
          value.freeze
        end
      end

      def descriptor_error(path, message)
        Hive::ConfigError.new("workflow descriptor #{path}: #{message}")
      end
    end
  end
end
