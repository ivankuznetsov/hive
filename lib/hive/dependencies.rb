require "hive/stages"
require "hive/config"
require "json"
require "psych"

module Hive
  module Dependencies
    TASK_SLUG_RE = /\A[a-z](?:[a-z0-9-]{0,62}[a-z0-9])?\z/
    PROJECT_NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    class InvalidReference < ArgumentError
      attr_reader :value

      def initialize(value, message = nil)
        @value = value
        super(message || "invalid dependency reference #{value.inspect}")
      end
    end

    Reference = Data.define(:project, :task, :explicit_project) do
      def to_s
        explicit_project ? "#{project}:#{task}" : task
      end
    end

    module_function

    def parse_reference(value)
      unless value.is_a?(String) || value.is_a?(Integer)
        raise InvalidReference.new(value, "depends_on must be one scalar task reference")
      end

      string = value.to_s.strip
      raise InvalidReference.new(value, "depends_on must not be blank") if string.empty?

      parts = string.split(":", -1)
      case parts.length
      when 1
        task = parts.first
        unless numeric?(task) || TASK_SLUG_RE.match?(task)
          raise InvalidReference.new(value, "depends_on must be a task slug, numeric id, or project:slug")
        end
        Reference.new(project: nil, task: task, explicit_project: false)
      when 2
        project, task = parts
        unless PROJECT_NAME_RE.match?(project) && TASK_SLUG_RE.match?(task) && !numeric?(task)
          raise InvalidReference.new(value, "cross-project depends_on must use project:slug")
        end
        Reference.new(project: project, task: task, explicit_project: true)
      else
        raise InvalidReference.new(value, "depends_on contains too many ':' separators")
      end
    end

    # Parse the authoritative dependency declaration without erasing whether
    # the author supplied one scalar edge or a scheduling-only list. Arrays
    # are deliberately not collapsed when they contain only one unique item.
    def parse_declaration(value)
      return parse_reference(value) unless value.is_a?(Array)

      raise InvalidReference.new(value, "depends_on list must not be empty") if value.empty?

      references = value.each_with_index.map do |element, index|
        if element.is_a?(Array) || element.is_a?(Hash) || element.nil?
          raise InvalidReference.new(
            value,
            "depends_on element #{index + 1} must be a scalar task reference"
          )
        end

        parse_reference(element)
      rescue InvalidReference => e
        raise e if e.value.equal?(value)

        raise InvalidReference.new(value, "depends_on element #{index + 1} is invalid: #{e.message}")
      end

      references.uniq { |reference| reference.to_s }
    end

    def parse_optional_declaration(value)
      return nil if value.nil?

      parse_declaration(value)
    end

    def normalize_declaration(value)
      parsed = parse_optional_declaration(value)
      serialize_declaration(parsed)
    end

    def serialize_declaration(value)
      return nil if value.nil?
      return value.map(&:to_s) if value.is_a?(Array)

      value.to_s
    end

    # Render malformed declaration evidence as schema-safe, readable text.
    # Composite values use JSON rather than Ruby's hash-rocket inspect syntax;
    # non-JSON scalars still degrade to their ordinary string representation.
    def display_declaration(value)
      return value.to_s if value.is_a?(String) || value.is_a?(Integer)

      JSON.generate(value)
    rescue JSON::GeneratorError, TypeError
      value.to_s
    end

    def declaration_references(value)
      parsed = parse_optional_declaration(value)
      parsed.is_a?(Array) ? parsed : Array(parsed)
    end

    # The project a reference names. A bare reference always means the
    # depending task's own project; it never searches other projects.
    # Admission resolves targets with this rule, so anything that compares
    # references outside admission must use it too.
    def reference_project(reference, current_project)
      reference.explicit_project ? reference.project : current_project
    end

    # What a reference points at, independent of spelling: `app:slug` and a
    # bare `slug` written in project `app` are the same edge. A bare numeric
    # id stays distinct from every slug because only admission can resolve it.
    def reference_identity(reference, current_project)
      [ reference_project(reference, current_project), reference.task ].freeze
    end

    def list_declaration?(value)
      value.is_a?(Array)
    end

    # Psych accepts duplicate mapping keys and silently keeps the last value.
    # Dependency declarations are policy evidence, so two top-level copies are
    # ambiguous and must fail closed instead of depending on parser ordering.
    def duplicate_top_level_key?(yaml, key)
      mapping = Psych.parse(yaml)&.root
      return false unless mapping.is_a?(Psych::Nodes::Mapping)

      seen = false
      mapping.children.each_slice(2) do |key_node, _value_node|
        next unless key_node.is_a?(Psych::Nodes::Scalar) && key_node.value == key
        return true if seen

        seen = true
      end
      false
    end

    def blocker_names(unmet_dependencies:, blocked_by: nil)
      names = Array(unmet_dependencies).filter_map do |entry|
        value = field(entry, :blocked_by).to_s.strip
        value = field(entry, :reference).to_s.strip if value.empty?
        value unless value.empty?
      end
      fallback = blocked_by.to_s.strip
      names << fallback if names.empty? && !fallback.empty?
      names.uniq
    end

    # Undecorated blocker summary shared by human and structured renderers.
    # The complete unmet collection is authoritative; scalar singulars are
    # compatibility fallbacks only.
    def blocker_summary(depends_on:, blocked_by:, dependency_stage:, unmet_dependencies: [])
      blockers = Array(unmet_dependencies).filter_map do |entry|
        reference = field(entry, :reference)
        target = field(entry, :blocked_by)
        stage = field(entry, :dependency_stage)
        gate = field(entry, :required_gate)
        name = target.to_s.strip.empty? ? reference.to_s.strip : target.to_s.strip
        next if name.empty?

        if target.to_s.strip.empty?
          "#{name} (unresolved)"
        elsif gate.to_s == Hive::Config::DEPENDENCY_GATE_STAGES.last
          "#{name} (#{stage}, needs #{gate})"
        else
          "#{name} (#{stage})"
        end
      end
      if blockers.empty?
        blockers << if !blocked_by.to_s.strip.empty?
          "#{blocked_by} (#{dependency_stage})"
        elsif !depends_on.is_a?(Array) && !depends_on.to_s.strip.empty?
          "#{depends_on} (unresolved)"
        else
          "a task dependency"
        end
      end
      "blocked by #{blockers.join(', ')}"
    end

    # Single source of truth for the decorated status/TUI indicator.
    def blocked_label(**attributes)
      "⏸ #{blocker_summary(**attributes)}"
    end

    def base_branch_for(depends_on:, tasks:, default_branch:, task: nil)
      return default_branch if list_declaration?(depends_on)

      return default_branch if depends_on.nil?

      dependency = parse_reference(depends_on).to_s

      prerequisite = find_task(dependency, tasks)
      return default_branch if prerequisite.nil? || same_task?(prerequisite, task)

      task_slug(prerequisite) || default_branch
    end

    def find_task(depends_on, tasks)
      tasks.find { |candidate| task_slug(candidate) == depends_on } ||
        (numeric?(depends_on) ? tasks.find { |candidate| task_id(candidate) == Integer(depends_on) } : nil)
    end

    def numeric?(value)
      value.to_s.match?(/\A\d+\z/)
    end

    def same_task?(left, right)
      return false unless right

      left_slug = task_slug(left)
      right_slug = task_slug(right)
      return true if left_slug && right_slug && left_slug == right_slug

      left_id = task_id(left)
      right_id = task_id(right)
      left_id && right_id && left_id == right_id
    end

    def task_slug(task)
      field(task, :slug)
    end

    def task_id(task)
      raw = field(task, :id)
      return raw if raw.is_a?(Integer)
      return nil if raw.nil? || raw.to_s.strip.empty?

      Integer(raw)
    rescue ArgumentError, TypeError
      # A corrupt prerequisite id cannot satisfy the numeric branch selector.
      # TaskMeta normally coerces it to nil before this helper sees it; keep a
      # breadcrumb for raw integration inputs.
      warn "[hive] dependencies: prerequisite id #{raw.inspect} is not an integer; " \
           "ignoring it for numeric depends_on matching"
      nil
    end

    # Read `key` (a symbol) from a supported task shape: symbol-keyed Hash,
    # string-keyed Hash, or an object exposing `key` as a reader. Status and
    # TUI blocker payloads exercise the string-keyed path, while dependency
    # snapshots exercise readers. Returns nil only when the key is absent from a
    # recognized shape; warns (and returns nil) when `task` is neither
    # hash-like nor a reader-exposing object, so a wrong-shaped caller leaves
    # a breadcrumb instead of silently resolving every field to "missing".
    def field(task, key)
      if task.respond_to?(:key?)
        return task[key] if task.key?(key)
        return task[key.to_s] if task.key?(key.to_s)

        nil
      elsif task.respond_to?(key)
        task.public_send(key)
      else
        warn "[hive] dependencies: unrecognized task shape #{task.class} " \
             "(expected Hash or object responding to #{key}); treating #{key} as missing"
        nil
      end
    end
  end
end
