require "json"
require "hive/dependencies"
require "hive/plan_frontmatter"
require "hive/dependency_snapshot"

module Hive
  module DependencyEdit
    module_function

    def request(references:, clear:)
      values = Array(references)
      unless clear ? values.empty? : !values.empty?
        raise ArgumentError, "supply --depends-on (repeatable) or --clear, exclusively"
      end
      return nil if clear

      Dependencies.normalize_declaration(values.one? ? values.first : values)
    end

    # Source coordinates from Psych count characters, not UTF-8 bytes. Keep
    # the source UTF-8 throughout slicing and only serialize at the boundary.
    class Document
      attr_reader :source, :value, :present

      def initialize(bytes)
        @source = bytes.dup.force_encoding(Encoding::UTF_8)
        raise ArgumentError, "YAML must be UTF-8" unless source.valid_encoding?

        stream = Psych.parse_stream(source)
        raise ArgumentError, "expected one YAML document" if stream.children.length > 1

        @mapping = stream.children.first&.root
        if @mapping.nil?
          @mapping = Psych::Nodes::Mapping.new(nil, nil, true, Psych::Nodes::Mapping::BLOCK)
          @mapping.start_line = source.lines.length
          @mapping.end_line = source.lines.length
          @mapping.start_column = @mapping.end_column = 0
        end
        raise ArgumentError, "YAML must contain a mapping" unless @mapping.is_a?(Psych::Nodes::Mapping)

        validate_nodes!(@mapping)
        @data = YAML.safe_load(source, permitted_classes: [Time, Date], aliases: false) || {}
        @pair = @mapping.children.each_slice(2).find { |key, _| key.value == "depends_on" }
        @present = !@pair.nil?
        @value = @present ? Dependencies.normalize_declaration(@data.fetch("depends_on")) : nil
        raise ArgumentError, "depends_on must be a reference or nonempty list" if @present && @value.nil?
      rescue Psych::Exception => error
        raise ArgumentError, "invalid dependency YAML: #{error.message}"
      end

      def assertion
        { "present" => present, "value" => value }
      end

      def edit(proposed)
        return source if value == proposed && (present || proposed.nil?)
        return insert(proposed) unless present

        key, node = @pair
        ending = node
        ending = ending.children.last while ending.is_a?(Psych::Nodes::Sequence) && ending.style == Psych::Nodes::Sequence::BLOCK && !ending.children.empty?
        value_end = offset(ending.end_line, ending.end_column)
        if proposed
          first = offset(node.start_line, node.start_column)
          suffix = source[first...value_end].end_with?("\n") ? (source.include?("\r\n") ? "\r\n" : "\n") : ""
          return splice(first, value_end, JSON.generate(proposed) + suffix)
        end

        first = offset(key.start_line, key.start_column)
        last = value_end
        if @mapping.style == Psych::Nodes::Mapping::FLOW
          following = source[last...offset(@mapping.end_line, @mapping.end_column) - 1]
          if (match = following.match(/\A\s*,\s*/))
            last += match[0].length
          elsif (comma = source[0...first].rindex(",")) && comma >= offset(@mapping.start_line, @mapping.start_column)
            first = comma
          end
        else
          first = offset(key.start_line, 0)
          # Collection end coordinates can already point at the next line.
          last = source.index("\n", last)&.+(1) || source.length unless ending.end_column.zero?
        end
        splice(first, last, "")
      end

      private

      def validate_nodes!(node)
        if node.is_a?(Psych::Nodes::Alias) || (node.respond_to?(:anchor) && node.anchor)
          raise ArgumentError, "YAML anchors and aliases are unsupported for dependency editing"
        end
        if node.is_a?(Psych::Nodes::Mapping)
          seen = {}
          node.children.each_slice(2) do |key, _|
            unless key.is_a?(Psych::Nodes::Scalar) && key.value != "<<"
              raise ArgumentError, "ambiguous YAML mapping key"
            end
            raise ArgumentError, "duplicate YAML key #{key.value.inspect}" if seen[key.value]

            seen[key.value] = true
          end
        end
        Array(node.children).each { |child| validate_nodes!(child) } if node.respond_to?(:children)
      end

      def offset(line, column)
        source.lines.take(line).sum(&:length) + column
      end

      def splice(first, last, replacement)
        source[0...first] + replacement + source[last..].to_s
      end

      def insert(proposed)
        return source if proposed.nil?

        if @mapping.style == Psych::Nodes::Mapping::FLOW
          position = offset(@mapping.end_line, @mapping.end_column) - 1
          splice(position, position, "#{@mapping.children.empty? ? '' : ', '}depends_on: #{JSON.generate(proposed)}")
        else
          newline = source.include?("\r\n") ? "\r\n" : "\n"
          position = offset(@mapping.end_line, 0)
          prefix = position.positive? && source[position - 1] != "\n" ? newline : ""
          splice(position, position, "#{prefix}depends_on: #{JSON.generate(proposed)}#{newline}")
        end
      end
    end

    Proposal = Data.define(:original, :intended, :before, :after, :verdict) do
      def changed? = original.transform_values { |bytes| bytes&.b } != intended.transform_values { |bytes| bytes&.b }
    end

    def prepare(task, value:, stage: "#{task.stage_index}-#{task.stage_name}", registry_entries: Config.registered_projects)
      original = { "meta.yml" => File.binread(File.join(task.folder, "meta.yml")) }
      plan_path = File.join(task.folder, "plan.md")
      original["plan.md"] = File.file?(plan_path) ? File.binread(plan_path) : nil
      metadata = Document.new(original.fetch("meta.yml"))
      intended = original.merge("meta.yml" => metadata.edit(value))
      plan, edited_plan = PlanFrontmatter.edit_dependency(original["plan.md"], value)
      intended["plan.md"] = edited_plan
      before = { "metadata_dependency" => metadata.assertion, "plan_dependency" => plan }
      after = { "metadata_dependency" => { "present" => !value.nil?, "value" => value },
                "plan_dependency" => { "present" => plan["present"] && !value.nil?, "value" => plan["present"] ? value : nil } }
      verdict = DependencySnapshot.edited_task_verdict(task, depends_on: value,
        plan_dependency: after.fetch("plan_dependency").fetch("value"), stage: stage, registry_entries: registry_entries)
      if verdict.error?
        error = verdict.admission_error
        raise Hive::DependencyAdmissionError.new("dependency edit rejected: #{error.reason_code}; #{error.safe_correction}", **error.to_h.transform_keys(&:to_sym))
      end
      Proposal.new(original: original, intended: intended, before: before, after: after, verdict: verdict)
    end
  end
end
