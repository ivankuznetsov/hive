require "psych"
require_relative "path_safety"
require_relative "scenario"

module Hive
  module E2E
    class ScenarioParser
      class InvalidScenario < StandardError
        attr_reader :path, :line, :reason

        def initialize(path:, line:, reason:)
          @path = path
          @line = line
          @reason = reason
          super("#{path}:#{line}: #{reason}")
        end
      end

      STEP_KINDS = %w[
        cli tui_keys tui_expect tui_refute state_assert json_assert seed_state write_file
        register_project wait_subprocess editor_action log_assert ruby_block
        start_releases_stub spawn_background stop_process
        script_gh
      ].freeze

      REQUIRED_KEYS = {
        "cli" => %w[args],
        "tui_expect" => %w[anchor],
        "tui_refute" => %w[anchor],
        "state_assert" => %w[path],
        "json_assert" => %w[args schema],
        "seed_state" => %w[stage],
        "write_file" => %w[path content],
        "register_project" => %w[name],
        "editor_action" => %w[args],
        "log_assert" => %w[path match],
        "ruby_block" => %w[block],
        "start_releases_stub" => %w[tag],
        "spawn_background" => %w[id args],
        "stop_process" => %w[id],
        "script_gh" => %w[interactions]
      }.freeze

      INCIDENT_TAG = "incident-regression"
      INCIDENT_ID = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
      SIBLING_TASK_ID = /\A#\d+\z/

      def self.parse(path)
        new(path).parse
      end

      def initialize(path)
        @path = path
      end

      def parse
        data = Psych.safe_load(File.read(@path), aliases: true, permitted_classes: [ Symbol ]) || {}
        invalid!("scenario root must be a map", 1) unless data.is_a?(Hash)

        name = safe_scenario_name(required_string(data, "name"))
        description = data["description"].to_s
        tags = Array(data["tags"]).map(&:to_s)
        incident_id, sibling_task_id, pending = parse_incident_metadata(data, description, tags)
        steps = parse_steps(data["steps"])
        Scenario.new(
          name: name,
          description: description,
          tags: tags,
          setup: data["setup"].is_a?(Hash) ? data["setup"] : {},
          steps: steps.freeze,
          path: @path,
          incident_id: incident_id,
          sibling_task_id: sibling_task_id,
          pending: pending
        ).freeze
      rescue Psych::SyntaxError => e
        invalid!(e.message, e.line)
      end

      private

      def parse_incident_metadata(data, description, tags)
        incident = tags.include?(INCIDENT_TAG) || %w[incident_id sibling_task_id pending].any? { |key| data.key?(key) }
        return [ nil, nil, false ] unless incident

        invalid!("incident description must be non-empty", metadata_line(data)) if description.strip.empty?

        incident_id = data["incident_id"].to_s
        unless INCIDENT_ID.match?(incident_id)
          invalid!("incident_id must be a lowercase kebab-case identifier", line_for("incident_id"))
        end

        sibling_task_id = data["sibling_task_id"].to_s
        unless SIBLING_TASK_ID.match?(sibling_task_id)
          invalid!("sibling_task_id must match #<digits>", line_for("sibling_task_id"))
        end

        pending = data.fetch("pending", false)
        unless pending == true || pending == false
          invalid!("pending must be true or false", line_for("pending"))
        end

        [ incident_id, sibling_task_id, pending ]
      end

      def metadata_line(data)
        %w[incident_id sibling_task_id pending tags name].each do |key|
          return line_for(key) if data.key?(key)
        end
        1
      end

      def parse_steps(raw)
        invalid!("scenario must have at least one step", line_for("steps")) unless raw.is_a?(Array) && raw.any?

        raw.map.with_index(1) do |step, idx|
          invalid!("step #{idx} must be a map", line_for("steps")) unless step.is_a?(Hash)

          kind = step["kind"].to_s
          invalid!("unknown step kind #{kind.inspect}", line_for(kind)) unless STEP_KINDS.include?(kind)
          required_step_keys(kind).each do |key|
            invalid!("#{kind} step missing #{key.inspect}", line_for(kind)) unless step.key?(key)
          end
          validate_step_types(kind, step)
          args = step.reject { |key, _| %w[kind description].include?(key) }
          Step.new(kind: kind, args: args.freeze, description: step["description"].to_s, position: idx).freeze
        end
      end

      def validate_step_types(kind, step)
        case kind
        when "cli", "json_assert", "editor_action", "spawn_background"
          invalid!("#{kind}.args must be an array", line_for(kind)) unless step["args"].is_a?(Array)
        when "tui_keys"
          key_count = %w[keys text].count { |key| step.key?(key) }
          invalid!("tui_keys step needs exactly one of keys or text", line_for(kind)) unless key_count == 1
        when "script_gh"
          invalid!("script_gh.interactions must be an array", line_for(kind)) unless step["interactions"].is_a?(Array)
        end
      end

      def required_step_keys(kind)
        REQUIRED_KEYS.fetch(kind, [])
      end

      def required_string(data, key)
        value = data[key]
        invalid!("missing #{key.inspect}", line_for(key)) if value.nil? || value.to_s.empty?

        value.to_s
      end

      def safe_scenario_name(value)
        PathSafety.safe_basename!(value, "scenario name")
      rescue ArgumentError => e
        invalid!(e.message, line_for("name"))
      end

      def invalid!(reason, line)
        raise InvalidScenario.new(path: @path, line: line || 1, reason: reason)
      end

      def line_for(text)
        needle = text.to_s
        index = File.readlines(@path).find_index { |line| line.include?(needle) }
        index ? index + 1 : 1
      rescue Errno::ENOENT
        1
      end
    end
  end
end
