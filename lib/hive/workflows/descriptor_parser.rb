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
        validate_terminal_last_stage!(stages, path: path)

        build_workflow(id, stages, path: path)
      end

      # A project workflow's last stage must be terminal (kind: terminal →
      # :inert). `Hive::Workflows.all_terminal_stage_dirs` treats every workflow's
      # last stage dir as the archive guard, and a task at the final stage has
      # nowhere to advance — so a descriptor ending in `kind: agent` yields a task
      # that can neither advance NOR drop (brainstorm A4). The blank scaffold
      # (inbox -> work -> done, kind: terminal) already complies. Built-in
      # workflows are Ruby-constructed and bypass this parser (coding's 9-done is
      # inert; content's terminal stage is intentionally an agent), so the rule is
      # scoped to owner-authored YAML descriptors. Skip the empty case — Workflow.new
      # raises its own "at least one stage" error.
      def validate_terminal_last_stage!(stages, path:)
        return if stages.empty?

        last = stages.last
        return if last.kind == :inert

        raise descriptor_error(
          path,
          "last stage #{last.name.inspect} must be a terminal stage (kind: terminal); a task at the " \
          "final stage cannot advance, so a non-terminal last stage would be undroppable"
        )
      end

      # Narrowed to JUST the Workflow.new construction. `validate_structure!`
      # raises ArgumentError for descriptor-level structural problems (gapped
      # indices, duplicate stage names/dirs, an unknown kind), which we relabel
      # as a user-facing descriptor ConfigError. (The non-terminal-last-stage
      # rule is enforced earlier and separately by `validate_terminal_last_stage!`,
      # which raises ConfigError before this method runs.)
      # Wrapping the whole parse body (as before) would mislabel an unrelated
      # wrong-kwarg bug in a future Stage.new/Workflow.new signature change as a
      # descriptor error, hiding a genuine code bug from the maintainer.
      def build_workflow(id, stages, path:)
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
        reject_agent_only_fields!(stage, kind: kind, path: path, label: label)
        skill = optional_string(stage["skill"], path: path, label: "#{label} skill")
        instruction = parse_instruction(stage["instruction"], path: path, label: label)
        permissions = parse_permissions(stage, id: id, stage_name: name, path: path, label: label)
        validate_agent_instruction!(skill: skill, instruction: instruction, path: path, label: label) if kind == :agent

        Hive::Workflow::Stage.new(
          name: name,
          index: index,
          state_file: parse_state_file(stage["state_file"], path: path, label: label),
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

      # `state_file` is joined onto `task.folder` at run time
      # (`File.join(task.folder, stage.state_file)` in Hive::Stages::Agent, and
      # the same value flows into Markers.set → ensure_dir/mkdir_p + write_atomic).
      # Unlike `id`/`name` it was previously only `required_string`-guarded, so a
      # descriptor with `state_file: ../../escape.md` — an authoring typo as much
      # as malice — would make hive mkdir/write marker files OUTSIDE the task
      # folder. Built-in descriptors all use bare basenames; reject any value
      # that could escape: no leading "/" (absolute) and no ".." path segment.
      def parse_state_file(value, path:, label:)
        file = required_string(value, path: path, label: "#{label} state_file")
        return file unless file.start_with?("/") || file.split("/").include?("..")

        raise descriptor_error(
          path,
          "#{label} state_file #{file.inspect} must stay inside the task folder " \
          "(no leading '/', no '..' path segment)"
        )
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

      # `skill`, `instruction`, and `permissions` are consumed ONLY by the agent
      # stage runner (Hive::Stages::Agent). On a terminal (inert) stage they are
      # validated, deep-frozen, and stored but never read — a silent no-op config
      # trap. Reject them at parse time (fail-fast, consistent with the parser's
      # other strict checks) so a typo'd-kind or misplaced field surfaces at load
      # rather than vanishing at run time.
      def reject_agent_only_fields!(stage, kind:, path:, label:)
        return if kind == :agent

        present = %w[skill instruction permissions].select { |key| stage.key?(key) }
        return if present.empty?

        raise descriptor_error(
          path,
          "#{label} #{present.inspect} #{present.one? ? 'is' : 'are'} only valid on an agent stage " \
          "(kind: agent), not a #{stage['kind'].inspect} stage"
        )
      end

      def validate_agent_instruction!(skill:, instruction:, path:, label:)
        # Exactly one of skill/instruction must be present. `optional_string`
        # already normalized blanks to nil, so `compact.one?` reads more
        # plainly than an XOR over the two `nil?` results.
        return if [ skill, instruction ].compact.one?

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
