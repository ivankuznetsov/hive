require "digest"
require "hive/task_capabilities/definition"

module Hive
  module TaskCapabilities
    # Definitions are immutable; project configuration can only add new IDs.
    class Catalog
      attr_reader :workflow, :definitions, :source

      def initialize(workflow:, definitions: [], source: "project task_capabilities", include_defaults: true)
        @workflow = workflow
        @source = source.to_s.freeze
        raise Hive::ConfigError, "#{source} catalog must be an array" unless definitions.is_a?(Array)
        @definitions = workflow.task_capabilities.dup
        known = @definitions.map(&:id)
        project_definitions = []
        definitions.each do |raw|
          definition = Definition.new(raw, stages: workflow.stages, source: source)
          if known.include?(definition.id)
            raise Hive::ConfigError, "#{source} capability #{definition.id.inspect} collides with workflow descriptor; descriptor is authoritative"
          end
          if @definitions.any? { |entry| entry.id == definition.id }
            raise Hive::ConfigError, "#{source} duplicate capability #{definition.id.inspect}"
          end
          @definitions << definition
          project_definitions << definition
        end
        if include_defaults && workflow.id == :coding
          require "hive/workflows/coding"
          defaults = Hive::Workflows::Coding::TASK_CAPABILITY_DEFAULTS.filter_map do |raw|
            next if @definitions.any? { |entry| entry.id == raw.fetch("id") }
            Definition.new(raw, stages: workflow.stages, source: "built-in coding capability")
          end
          @definitions = (defaults + @definitions).sort_by do |entry|
            builtin_ids = Hive::Workflows::Coding::TASK_CAPABILITY_DEFAULTS.map { |raw| raw.fetch("id") }
            [ builtin_ids.index(entry.id) || builtin_ids.length, project_definitions.index(entry) || 0 ]
          end
        end
        validate_graph!
        @definitions.freeze
        freeze
      end

      def fetch(id)
        definitions.find { |definition| definition.id == id } ||
          raise(Hive::ConfigError, "#{source} unknown capability #{id.inspect}")
      end

      def to_h = Definition.deep_freeze({ "definitions" => definitions.map(&:to_h) })
      def digest = ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(to_h))

      def ordered(selected, stage:)
        entries = Definition.strings(selected, label: "#{source} selected capabilities").map { |id| fetch(id) }
        entries.each do |entry|
          missing = entry.data.fetch("depends_on") - selected
          raise Hive::ConfigError, "#{source} capability #{entry.id.inspect} has unsatisfied dependencies: #{missing.join(', ')}" unless missing.empty?
          conflicts = entry.data.fetch("conflicts") & selected
          raise Hive::ConfigError, "#{source} capability #{entry.id.inspect} conflicts with #{conflicts.join(', ')}" unless conflicts.empty?
        end
        entries = entries.select { |entry| entry.stages.include?(stage) }
        output = []
        edges = order_edges(entries)
        until edges.empty?
          ready = edges.select { |_id, deps| deps.empty? }.keys
          ready.sort_by { |id| definitions.index(fetch(id)) }.each do |id|
            output << fetch(id)
            edges.delete(id)
          end
          edges.each_value { |deps| deps.reject! { |id| ready.include?(id) } }
        end
        output.freeze
      end

      private

      def validate_graph!
        ids = definitions.map(&:id)
        definitions.each do |entry|
          unknown_stages = entry.stages - workflow.stage_names
          raise Hive::ConfigError, "#{source} capability #{entry.id.inspect} has unknown stage bindings" unless unknown_stages.empty?
          if workflow.id == :coding
            if %w[qa security].include?(entry.id) && entry.kind != "verification"
              raise Hive::ConfigError, "#{source} capability #{entry.id.inspect} must be verification"
            end
            if entry.kind == "verification" && entry.stages != [ "review" ]
              raise Hive::ConfigError, "#{source} verification capability #{entry.id.inspect} must attach within review"
            end
            if entry.id == "ui" && (entry.kind != "guidance" || entry.stages != %w[plan execute])
              raise Hive::ConfigError, "#{source} UI guidance must attach to plan and execute"
            end
          end
          %w[depends_on conflicts before after].each do |key|
            unknown = entry.data.fetch(key) - ids
            raise Hive::ConfigError, "#{source} capability #{entry.id.inspect} #{key} references unknown IDs: #{unknown.join(', ')}" unless unknown.empty?
          end
          required = dependency_closure(entry.id)
          if required.include?(entry.id) || !(entry.data.fetch("conflicts") & required).empty? ||
             required.any? { |id| fetch(id).data.fetch("conflicts").include?(entry.id) }
            raise Hive::ConfigError, "#{source} capability #{entry.id.inspect} has cyclic dependencies or conflicts with a required capability"
          end
          %w[before after].each do |key|
            entry.data.fetch(key).each do |id|
              if (entry.stages & fetch(id).stages).empty?
                raise Hive::ConfigError, "#{source} capability #{entry.id.inspect} #{key} #{id.inspect} has no shared stage attachment"
              end
            end
          end
        end
        Definition.acyclic!(definitions.to_h { |entry| [ entry.id, entry.data.fetch("depends_on") ] }, label: "#{source} dependencies")
        workflow.stages.each do |stage|
          Definition.acyclic!(order_edges(definitions.select { |entry| entry.stages.include?(stage.name) }), label: "#{source} stage #{stage.name} order")
        end
      end

      def dependency_closure(id, seen = [])
        fetch(id).data.fetch("depends_on").each_with_object([]) do |dependency, result|
          result << dependency
          result.concat(dependency_closure(dependency, seen + [ id ])) unless (seen + [ id ]).include?(dependency)
        end.uniq
      end

      def order_edges(entries)
        ids = entries.map(&:id)
        edges = entries.to_h { |entry| [ entry.id, (entry.data.fetch("after") + entry.data.fetch("depends_on")) & ids ] }
        entries.each do |entry|
          (entry.data.fetch("before") & ids).each { |id| edges.fetch(id) << entry.id }
        end
        edges
      end
    end
  end
end
