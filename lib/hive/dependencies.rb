require "hive/stages"
require "hive/config"
require "date"
require "json"
require "psych"

module Hive
  module Dependencies
    TASK_SLUG_RE = /\A[a-z](?:[a-z0-9-]{0,62}[a-z0-9])?\z/
    PROJECT_NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
    SHORTHAND_CODE_RE = /\A[A-Za-z][A-Za-z0-9-]*\z/

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

    DeclarationEntry = Data.define(:index, :raw_value, :reference)

    DeclarationIssue = Data.define(
      :index, :raw_value, :display_value, :code, :message, :suggestion
    ) do
      def initialize(index: nil, raw_value: nil, display_value: nil, code:, message:, suggestion: nil)
        safe_raw = Hive::Dependencies.json_safe_value(raw_value)
        rendered = display_value.nil? ? Hive::Dependencies.safe_issue_display(raw_value) : display_value.to_s
        super(
          index: index,
          raw_value: safe_raw,
          display_value: rendered,
          code: code.to_sym,
          message: message.to_s,
          suggestion: suggestion
        )
      end

      def to_h
        {
          "index" => index,
          "raw_value" => raw_value,
          "display_value" => display_value,
          "code" => code.to_s,
          "message" => message,
          "suggestion" => suggestion
        }
      end
    end

    DeclarationInspection = Data.define(:valid, :list, :parsed, :entries, :issues, :raw_value) do
      def valid? = valid
      def list? = list

      def summary_message
        return nil if valid?

        issues.map(&:message).join("; ")
      end
    end

    ELEMENT_ISSUE_CODES = %i[
      task_code_shorthand
      invalid_reference
      unresolved_reference
      nested_element
      empty_list
      invalid_shape
    ].freeze

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

    # Inspect a raw declaration without stopping on the first element failure.
    # Preserves every zero-based element index, raw value, valid parsed entries,
    # and all per-element syntax issues so downstream validators can also check
    # reference resolution on valid siblings in the same list.
    def inspect_declaration(value)
      safe_raw = json_safe_value(value)
      if value.is_a?(Array)
        if value.empty?
          issue = DeclarationIssue.new(
            index: nil, raw_value: value, display_value: "[]",
            code: :empty_list, message: "depends_on list must not be empty"
          )
          return DeclarationInspection.new(
            valid: false, list: true, parsed: nil,
            entries: [].freeze, issues: [ issue ].freeze, raw_value: safe_raw
          ).freeze
        end

        entries = []
        issues = []
        value.each_with_index do |element, index|
          if element.is_a?(Array) || element.is_a?(Hash) || element.nil?
            issues << DeclarationIssue.new(
              index: index, raw_value: element, code: :nested_element,
              message: "depends_on element #{index + 1} must be a scalar task reference"
            )
            next
          end

          begin
            reference = parse_reference(element)
            entries << DeclarationEntry.new(
              index: index, raw_value: json_safe_value(element), reference: reference
            ).freeze
          rescue InvalidReference => e
            issues << DeclarationIssue.new(
              index: index, raw_value: element,
              code: invalid_reference_code(element),
              message: "depends_on element #{index + 1} is invalid: #{e.message}"
            )
          end
        end

        parsed = issues.empty? ? entries.map(&:reference).uniq(&:to_s).freeze : nil
        return DeclarationInspection.new(
          valid: issues.empty?, list: true, parsed: parsed,
          entries: entries.freeze, issues: issues.freeze, raw_value: safe_raw
        ).freeze
      end

      if value.is_a?(Hash)
        issue = DeclarationIssue.new(
          index: nil, raw_value: value, code: :invalid_shape,
          message: "depends_on must be one scalar task reference or a nonempty flat list"
        )
        return DeclarationInspection.new(
          valid: false, list: false, parsed: nil,
          entries: [].freeze, issues: [ issue ].freeze, raw_value: safe_raw
        ).freeze
      end

      begin
        reference = parse_reference(value)
        entry = DeclarationEntry.new(
          index: nil, raw_value: safe_raw, reference: reference
        ).freeze
        DeclarationInspection.new(
          valid: true, list: false, parsed: reference,
          entries: [ entry ].freeze, issues: [].freeze, raw_value: safe_raw
        ).freeze
      rescue InvalidReference => e
        issue = DeclarationIssue.new(
          index: nil, raw_value: value,
          code: invalid_reference_code(value),
          message: e.message
        )
        DeclarationInspection.new(
          valid: false, list: false, parsed: nil,
          entries: [].freeze, issues: [ issue ].freeze, raw_value: safe_raw
        ).freeze
      end
    end

    def invalid_reference_code(value)
      return :task_code_shorthand if task_code_shorthand_token?(value)

      :invalid_reference
    end

    def task_code_shorthand_token?(value)
      return false unless value.is_a?(String)

      token = value.strip
      return false if token.empty? || numeric?(token)

      parts = token.split(":", -1)
      case parts.length
      when 1
        SHORTHAND_CODE_RE.match?(parts.first) && !TASK_SLUG_RE.match?(parts.first)
      when 2
        project, code = parts
        PROJECT_NAME_RE.match?(project) && SHORTHAND_CODE_RE.match?(code) &&
          !numeric?(code) && !TASK_SLUG_RE.match?(code)
      else
        false
      end
    end

    def hint_code_for(raw_value, current_project:)
      return nil unless raw_value.is_a?(String)

      token = raw_value.strip
      return nil if token.empty? || numeric?(token)

      parts = token.split(":", -1)
      case parts.length
      when 1
        SHORTHAND_CODE_RE.match?(parts.first) ? parts.first : nil
      when 2
        project, code = parts
        return nil unless project == current_project.to_s
        return nil if numeric?(code)

        SHORTHAND_CODE_RE.match?(code) ? code : nil
      else
        nil
      end
    end

    def slug_prefix_matches?(slug, code:)
      return false if slug.nil? || code.to_s.empty?

      normalized = code.to_s.downcase
      target = slug.to_s.downcase
      target == normalized || target.start_with?("#{normalized}-")
    end

    # Recognize only three nonempty colon-separated components
    # `<project>:<code>:<version>` where `<project>` matches the current
    # project and `<code>` matches the task code case-insensitively.
    def idempotency_key_matches?(key, project:, code:)
      return false if key.nil? || project.to_s.empty? || code.to_s.empty?

      parts = key.to_s.split(":", -1)
      return false unless parts.length == 3 && parts.none? { |part| part.strip.empty? }

      parts[0] == project.to_s && parts[1].casecmp?(code.to_s)
    end

    def json_safe_value(value)
      case value
      when Array
        value.map { |element| json_safe_value(element) }.freeze
      when Hash
        value.each_with_object({}) do |(key, element), safe|
          safe[json_safe_value(key).to_s] = json_safe_value(element)
        end.freeze
      when Float
        value.finite? ? value : value.to_s
      when Time
        value.utc.iso8601
      when Date
        value.iso8601
      when Symbol
        value.to_s
      else
        value
      end
    end

    def safe_issue_display(value)
      return JSON.generate(value) if value.is_a?(String) && value.strip.empty?
      return value.to_s if value.is_a?(String) || value.is_a?(Integer)
      return "null" if value.nil?

      display_declaration(value)
    end

    def format_invalid_depends_on(issues, fallback: nil)
      list = Array(issues)
      return fallback || "invalid depends_on" if list.empty?

      if list.all? { |issue| ELEMENT_ISSUE_CODES.include?(issue.code) }
        values = list.map(&:display_value).reject(&:empty?)
        return "invalid depends_on #{values.join(', ')}" unless values.empty?
      elsif list.any? { |issue| issue.code == :duplicate_depends_on }
        values = list.map(&:display_value).reject(&:empty?)
        return values.empty? ? "duplicate depends_on declarations" : "invalid depends_on (duplicate keys: #{values.join(', ')})"
      end

      fallback || list.first.message
    end

    def format_issue_details(issues)
      Array(issues).map do |issue|
        prefix = issue.index.nil? ? issue.display_value : "index #{issue.index}: #{issue.display_value}"
        if issue.suggestion && !issue.suggestion.empty?
          "#{prefix} (suggested: #{issue.suggestion})"
        else
          prefix
        end
      end.join("; ")
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
      return JSON.generate(json_safe_value(value)) if value.is_a?(Array) || value.is_a?(Hash)

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

    def blocker_names(unmet_dependencies:, blocked_by: nil, dependency_repair_roots: [])
      names = Array(unmet_dependencies).filter_map do |entry|
        value = field(entry, :blocked_by).to_s.strip
        value = field(entry, :reference).to_s.strip if value.empty?
        value unless value.empty?
      end
      fallback = blocked_by.to_s.strip
      names << fallback if names.empty? && !fallback.empty?
      Array(dependency_repair_roots).each do |root|
        qualified = repair_root_identity(root)
        names << qualified unless qualified.empty?
      end
      names.uniq
    end

    def repair_root_identity(root)
      project = field(root, :project).to_s.strip
      slug = field(root, :slug).to_s.strip
      return "" if slug.empty?

      project.empty? ? slug : "#{project}:#{slug}"
    end

    def repair_root_summary(root)
      qualified = repair_root_identity(root)
      reason_code = field(root, :reason_code).to_s.strip
      offending = field(root, :offending_ref).to_s.strip
      case reason_code
      when "plan_dependency_invalid"
        offending.empty? ? "#{qualified}: invalid depends_on" : "#{qualified}: invalid depends_on #{offending}"
      when "plan_dependency_mismatch"
        offending.empty? ? "#{qualified}: mismatched depends_on" : "#{qualified}: mismatched depends_on #{offending}"
      when "plan_dependency_missing"
        offending.empty? ? "#{qualified}: unadopted depends_on" : "#{qualified}: unadopted depends_on #{offending}"
      else
        offending.empty? ? "#{qualified}: #{reason_code}" : "#{qualified}: #{reason_code} #{offending}"
      end
    end

    def repair_roots_summary(dependency_repair_roots)
      Array(dependency_repair_roots).filter_map do |root|
        summary = repair_root_summary(root)
        summary unless summary.empty?
      end.join("; ")
    end

    def repair_root_matches_target?(root, target, current_project: nil)
      name = target.to_s.strip
      return false if name.empty?

      project = field(root, :project).to_s.strip
      slug = field(root, :slug).to_s.strip
      return false if slug.empty?

      if name.include?(":")
        name == "#{project}:#{slug}"
      elsif current_project && !current_project.to_s.empty?
        project == current_project.to_s && slug == name
      else
        slug == name
      end
    end

    # Undecorated blocker summary shared by human and structured renderers.
    # The complete unmet collection and inherited repair roots are authoritative;
    # scalar singulars are compatibility fallbacks only.
    def blocker_summary(depends_on:, blocked_by:, dependency_stage:, unmet_dependencies: [],
                        dependency_repair_roots: [], current_project: nil)
      roots = Array(dependency_repair_roots).reject { |root| repair_root_identity(root).empty? }
      blockers = Array(unmet_dependencies).filter_map do |entry|
        reference = field(entry, :reference)
        target = field(entry, :blocked_by)
        stage = field(entry, :dependency_stage)
        gate = field(entry, :required_gate)
        name = target.to_s.strip.empty? ? reference.to_s.strip : target.to_s.strip
        next if name.empty?
        next if roots.any? { |root| repair_root_matches_target?(root, name, current_project: current_project) }

        if target.to_s.strip.empty?
          "#{name} (unresolved)"
        elsif gate.to_s == Hive::Config::DEPENDENCY_GATE_STAGES.last
          "#{name} (#{stage}, needs #{gate})"
        else
          "#{name} (#{stage})"
        end
      end

      unless roots.empty?
        roots_text = repair_roots_summary(roots)
        return "blocked by #{roots_text}" if blockers.empty?

        return "blocked by #{roots_text}; #{blockers.join(', ')}"
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
