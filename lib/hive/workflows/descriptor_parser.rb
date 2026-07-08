require "yaml"
require "hive/agent_profiles"
require "hive/permission_scope"
require "hive/workflow"

module Hive
  module Workflows
    # Parses + validates ONE owner-authored YAML workflow descriptor into a
    # `Hive::Workflow`. An instance carries the source `@path` so every check
    # can build a path-attributed `ConfigError` without threading it through
    # each signature; `label:` (per-stage/field context) and `id:` (parsed
    # mid-flight) stay as arguments because they vary within a single parse.
    class DescriptorParser
      SAFE_SLUG = /\A[a-z0-9][a-z0-9-]*\z/
      TOP_LEVEL_KEYS = %w[id stages].freeze
      STAGE_KEYS = %w[
        name
        kind
        state_file
        advance_verb
        skill
        instruction
        agent
        model
        effort
        input
        reviewers
        council
        deliverable
        permissions
      ].freeze
      REVIEWER_KEYS = %w[
        name
        agent
        model
        effort
        skill
        instruction
        prompt
        command
        output_basename
        permissions
        max_attempts
      ].freeze
      COUNCIL_KEYS = %w[quorum max_rounds exit_rule triage_output revise].freeze
      REVISE_KEYS = %w[agent model effort skill instruction prompt command permissions].freeze
      REVIEWER_INSTRUCTION_KEYS = %w[skill instruction prompt command].freeze
      EXIT_RULES = %w[consensus human].freeze

      def self.parse_file(path) = new(path).parse_file
      def self.parse_hash(data, path:) = new(path).parse_hash(data)

      def initialize(path)
        @path = path
      end

      def parse_file
        parsed = YAML.safe_load(File.read(@path))
        parse_hash(parsed)
      rescue Psych::Exception => e
        raise descriptor_error("is not valid YAML: #{e.message}")
      rescue SystemCallError, IOError => e
        raise descriptor_error("is not readable: #{e.message}")
      end

      def parse_hash(data)
        descriptor = stringify_hash(data, label: "descriptor")
        reject_unknown_keys!(descriptor, TOP_LEVEL_KEYS, label: "descriptor")
        id = parse_id(descriptor["id"])
        validate_filename_id!(id)
        stages = parse_stages(descriptor["stages"], id: id)
        validate_terminal_last_stage!(stages)

        build_workflow(id, stages)
      end

      private

      # A project workflow's last stage may be inert or an active producer
      # (:agent/:council). Active terminal stages are gated at status time by
      # a terminal marker plus a non-empty deliverable artifact.
      def validate_terminal_last_stage!(stages)
        return if stages.empty?

        last = stages.last
        return if [ :inert, :agent, :council ].include?(last.kind)

        raise descriptor_error(
          "last stage #{last.name.inspect} must be terminal, agent, or council"
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
      def build_workflow(id, stages)
        Hive::Workflow.new(id: id.to_sym, stages: stages)
      rescue ArgumentError => e
        raise descriptor_error(e.message)
      end

      def parse_id(value)
        id = required_string(value, label: "id")
        return id if SAFE_SLUG.match?(id)

        raise descriptor_error("id #{id.inspect} must match #{SAFE_SLUG.source}")
      end

      def validate_filename_id!(id)
        expected = File.basename(@path, File.extname(@path))
        return if id == expected

        raise descriptor_error("id #{id.inspect} must match filename #{expected.inspect}")
      end

      def parse_stages(data, id:)
        unless data.is_a?(Array)
          raise descriptor_error("stages must be an array")
        end

        data.each_with_index.map do |stage_data, offset|
          parse_stage(stage_data, id: id, index: offset + 1)
        end
      end

      def parse_stage(data, id:, index:)
        label = "stage #{index}"
        stage = stringify_hash(data, label: label)
        reject_unknown_keys!(stage, STAGE_KEYS, label: label)
        name = parse_stage_name(stage["name"], label: label)
        kind = parse_kind(stage["kind"], label: label)
        reject_agent_only_fields!(stage, kind: kind, label: label)
        skill = optional_string(stage["skill"], label: "#{label} skill")
        instruction = parse_instruction(stage["instruction"], label: label)
        agent = parse_agent(stage["agent"], label: label)
        model = optional_string(stage["model"], label: "#{label} model")
        effort = optional_string(stage["effort"], label: "#{label} effort")
        permissions = parse_permissions(stage, id: id, stage_name: name, label: label)
        input = optional_string(stage["input"], label: "#{label} input")
        deliverable = parse_deliverable(stage["deliverable"], label: label)
        reviewers = parse_reviewers(stage["reviewers"], id: id, label: label) if kind == :council
        council = parse_council(stage["council"], id: id, label: label, reviewer_count: reviewers&.length) if kind == :council
        validate_agent_instruction!(skill: skill, instruction: instruction, label: label) if kind == :agent

        Hive::Workflow::Stage.new(
          name: name,
          index: index,
          state_file: parse_state_file(stage["state_file"], label: label),
          advance_verb: parse_advance_verb(stage, name: name, index: index, label: label),
          kind: kind,
          skill: skill,
          instruction: instruction,
          agent: agent,
          model: model,
          effort: effort,
          input: input,
          reviewers: reviewers,
          council: council,
          deliverable: deliverable,
          permissions: permissions
        )
      end

      def parse_stage_name(value, label:)
        name = required_string(value, label: "#{label} name")
        return name if SAFE_SLUG.match?(name)

        raise descriptor_error("#{label} name #{name.inspect} must match #{SAFE_SLUG.source}")
      end

      # `state_file` is joined onto `task.folder` at run time
      # (`File.join(task.folder, stage.state_file)` in Hive::Stages::Agent, and
      # the same value flows into Markers.set → ensure_dir/mkdir_p + write_atomic).
      # Unlike `id`/`name` it was previously only `required_string`-guarded.
      # Restrict it to a BARE BASENAME (no "/" path separator, not "." or ".."):
      # a leading "/" or a ".." segment escapes the task folder, but even a
      # benign-looking subdirectory like `sub/idea.md` is unwritable — `hive new`
      # only `mkdir_p`s the task folder before `File.write(File.join(task_dir,
      # state_file))`, so a nested path raises Errno::ENOENT and a descriptor that
      # PASSED validation could never capture its first task. Built-in descriptors
      # all use bare basenames (idea.md, work.md, …), so this matches the contract
      # the rest of the runner assumes and removes the nested-dir fragility in the
      # agent runner's output path.
      def parse_state_file(value, label:)
        file = required_string(value, label: "#{label} state_file")
        return file if file == File.basename(file) && ![ ".", ".." ].include?(file)

        raise descriptor_error(
          "#{label} state_file #{file.inspect} must be a bare filename inside the task folder " \
          "(no '/' path separator, not '.' or '..'); built-in stages use basenames like 'idea.md'"
        )
      end

      def parse_kind(value, label:)
        raw = required_string(value, label: "#{label} kind")
        case raw
        when "agent" then :agent
        when "council" then :council
        when "terminal" then :inert
        else
          raise descriptor_error("#{label} kind #{raw.inspect} must be agent, council, or terminal")
        end
      end

      def parse_instruction(value, label:)
        raw = optional_string(value, label: "#{label} instruction")
        return nil if raw.nil?

        resolved = File.expand_path(raw, File.dirname(@path))
        return resolved if File.file?(resolved) && File.readable?(resolved)

        raise descriptor_error("#{label} instruction #{raw.inspect} must reference a readable file (#{resolved})")
      end

      def parse_agent(value, label:)
        raw = optional_string(value, label: "#{label} agent")
        return nil if raw.nil?
        return raw if Hive::AgentProfiles.registered?(raw)

        raise descriptor_error(
          "#{label} agent #{raw.inspect} is not registered " \
          "(registered: #{Hive::AgentProfiles.registered_names.inspect})"
        )
      end

      def parse_deliverable(value, label:)
        return nil if value.nil?

        parse_state_file(value, label: "#{label} deliverable")
      end

      def parse_permissions(stage, id:, stage_name:, label:)
        return nil unless stage.key?("permissions")

        value = stage["permissions"]
        Hive::PermissionScope.validate!(value, stage: "#{id}.#{stage_name}")
        deep_freeze(value)
      rescue Hive::ConfigError => e
        raise descriptor_error("#{label} #{e.message}")
      end

      def parse_reviewers(data, id:, label:)
        raise descriptor_error("#{label} council stage must declare reviewers") if data.nil?
        raise descriptor_error("#{label} reviewers must be an array") unless data.is_a?(Array)
        raise descriptor_error("#{label} council stage must declare at least one reviewer") if data.empty?

        reviewers = data.each_with_index.map do |raw_reviewer, offset|
          parse_reviewer(raw_reviewer, id: id, label: "#{label} reviewer #{offset + 1}")
        end
        # Two reviewers sharing a name or output_basename resolve to the same
        # reviews/<base>-NN.md path — one overwrites the other and triage
        # double-counts the single surviving file toward quorum. Reject at load
        # time, mirroring Workflow#validate_structure!'s stage name/dir checks.
        reject_reviewer_duplicates!(reviewers.map(&:name), "reviewer names", label: label)
        reject_reviewer_duplicates!(reviewers.map(&:output_basename), "reviewer output_basenames", label: label)
        reviewers.freeze
      end

      def reject_reviewer_duplicates!(values, what, label:)
        return if values.uniq.length == values.length

        duplicates = values.select { |value| values.count(value) > 1 }.uniq
        raise descriptor_error("#{label} has duplicate #{what}: #{duplicates.inspect}")
      end

      def parse_reviewer(data, id:, label:)
        reviewer = stringify_hash(data, label: label)
        reject_unknown_keys!(reviewer, REVIEWER_KEYS, label: label)
        name = parse_stage_name(reviewer["name"], label: label)
        instruction_fields = REVIEWER_INSTRUCTION_KEYS.select { |key| reviewer.key?(key) && !reviewer[key].nil? }
        unless instruction_fields.length == 1
          raise descriptor_error("#{label} must declare exactly one of #{REVIEWER_INSTRUCTION_KEYS.join(', ')}")
        end

        Hive::Workflow::Reviewer.new(
          name: name,
          agent: parse_agent(reviewer["agent"], label: label),
          model: optional_string(reviewer["model"], label: "#{label} model"),
          effort: optional_string(reviewer["effort"], label: "#{label} effort"),
          skill: optional_string(reviewer["skill"], label: "#{label} skill"),
          instruction: parse_instruction(reviewer["instruction"], label: label),
          prompt: optional_string(reviewer["prompt"], label: "#{label} prompt"),
          command: optional_string(reviewer["command"], label: "#{label} command"),
          output_basename: optional_string(reviewer["output_basename"], label: "#{label} output_basename") || name,
          permissions: parse_permissions(reviewer, id: id, stage_name: name, label: label),
          max_attempts: optional_positive_integer(reviewer["max_attempts"], label: "#{label} max_attempts")
        )
      end

      def parse_council(data, id:, label:, reviewer_count:)
        council = data.nil? ? {} : stringify_hash(data, label: "#{label} council")
        reject_unknown_keys!(council, COUNCIL_KEYS, label: "#{label} council")
        quorum = optional_positive_integer(council["quorum"], label: "#{label} council quorum") || reviewer_count
        if quorum > reviewer_count
          raise descriptor_error("#{label} council quorum #{quorum} cannot exceed reviewer count #{reviewer_count}")
        end
        max_rounds = optional_positive_integer(council["max_rounds"], label: "#{label} council max_rounds") || 1
        exit_rule = optional_string(council["exit_rule"], label: "#{label} council exit_rule") || "human"
        unless EXIT_RULES.include?(exit_rule)
          raise descriptor_error("#{label} council exit_rule #{exit_rule.inspect} must be one of #{EXIT_RULES.inspect}")
        end

        revise = parse_revise(council["revise"], id: id, label: "#{label} council revise")
        # A revise agent only runs when the loop takes a second round
        # (`round >= max_rounds` short-circuits at the default max_rounds: 1),
        # so pairing revise with max_rounds: 1 is a silent no-op. Warn at load
        # time rather than fail — the descriptor is still runnable.
        if revise && max_rounds <= 1
          warn "hive: #{@path}: #{label} council declares a revise agent with max_rounds: 1; " \
               "revise never runs at max_rounds 1 (increase max_rounds to enable it)"
        end

        Hive::Workflow::Council.new(
          quorum: quorum,
          max_rounds: max_rounds,
          exit_rule: exit_rule.to_sym,
          triage_output: optional_string(council["triage_output"], label: "#{label} council triage_output") || Hive::Workflow::DEFAULT_TRIAGE_OUTPUT,
          revise: revise
        )
      end

      def parse_revise(data, id:, label:)
        return nil if data.nil?

        revise = stringify_hash(data, label: label)
        reject_unknown_keys!(revise, REVISE_KEYS, label: label)
        instruction_fields = REVIEWER_INSTRUCTION_KEYS.select { |key| revise.key?(key) && !revise[key].nil? }
        unless instruction_fields.length == 1
          raise descriptor_error("#{label} must declare exactly one of #{REVIEWER_INSTRUCTION_KEYS.join(', ')}")
        end

        Hive::Workflow::Revise.new(
          agent: parse_agent(revise["agent"], label: label),
          model: optional_string(revise["model"], label: "#{label} model"),
          effort: optional_string(revise["effort"], label: "#{label} effort"),
          skill: optional_string(revise["skill"], label: "#{label} skill"),
          instruction: parse_instruction(revise["instruction"], label: label),
          prompt: optional_string(revise["prompt"], label: "#{label} prompt"),
          command: optional_string(revise["command"], label: "#{label} command"),
          permissions: parse_permissions(revise, id: id, stage_name: "revise", label: label)
        )
      end

      def parse_advance_verb(stage, name:, index:, label:)
        return nil if index == 1 && !stage.key?("advance_verb")

        verb_name =
          if stage.key?("advance_verb")
            optional_string(stage["advance_verb"], label: "#{label} advance_verb")
          else
            name
          end
        return nil if verb_name.nil?

        Hive::Workflow::AdvanceVerb.new(name: verb_name)
      end

      # These fields are consumed by active stage runners — both :agent and
      # :council kinds (the guard below allows either). On a terminal (inert)
      # stage they are validated, deep-frozen, and stored but never read — a
      # silent no-op config trap. Reject them at parse time (fail-fast,
      # consistent with the parser's other strict checks) so a typo'd-kind or
      # misplaced field surfaces at load rather than vanishing at run time.
      def reject_agent_only_fields!(stage, kind:, label:)
        return if [ :agent, :council ].include?(kind)

        present = %w[skill instruction agent model effort input reviewers council deliverable permissions].select { |key| stage.key?(key) }
        return if present.empty?

        raise descriptor_error(
          "#{label} #{present.inspect} #{present.one? ? 'is' : 'are'} only valid on an agent stage " \
          "(kind: agent or council), not a #{stage['kind'].inspect} stage"
        )
      end

      def validate_agent_instruction!(skill:, instruction:, label:)
        # Exactly one of skill/instruction must be present. `optional_string`
        # already normalized blanks to nil, so `compact.one?` reads more
        # plainly than an XOR over the two `nil?` results.
        return if [ skill, instruction ].compact.one?

        raise descriptor_error("#{label} agent stages must declare exactly one of skill or instruction")
      end

      def stringify_hash(data, label:)
        unless data.is_a?(Hash)
          raise descriptor_error("#{label} must be a map")
        end

        data.each_with_object({}) do |(key, value), out|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise descriptor_error("#{label} contains non-string key #{key.inspect}")
          end

          out[key.to_s] = value
        end
      end

      def reject_unknown_keys!(data, allowed, label:)
        unknown = data.keys - allowed
        return if unknown.empty?

        raise descriptor_error("#{label} contains unknown key(s) #{unknown.inspect}")
      end

      def required_string(value, label:)
        string = optional_string(value, label: label)
        return string unless string.nil?

        raise descriptor_error("#{label} must be a non-empty string")
      end

      def optional_string(value, label:)
        return nil if value.nil?
        return value.strip if value.is_a?(String) && !value.strip.empty?

        raise descriptor_error("#{label} must be a non-empty string")
      end

      def optional_positive_integer(value, label:)
        return nil if value.nil?
        return value if value.is_a?(Integer) && value.positive?

        raise descriptor_error("#{label} must be a positive integer")
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

      def descriptor_error(message)
        Hive::ConfigError.new("workflow descriptor #{@path}: #{message}")
      end
    end
  end
end
