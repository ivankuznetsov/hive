require "json"
require "hive/config"
require "hive/workflow_selection"
require "hive/workflows/descriptor_parser"
require "hive/workflows/loader"
require "hive/workflows/registry"

module Hive
  module Commands
    class Workflow
      # Read-only validation through the same project overlay and workflow
      # resolver used by task creation. It deliberately does not repair or
      # normalize files on disk; the payload is a projection of the loaded
      # runtime graph.
      class Validate
        SCHEMA = "hive-workflow-validate".freeze

        def initialize(id, project_root:, json: false, stdout: $stdout)
          @id = id.to_s.strip
          @project_root = File.expand_path(project_root)
          @json = json
          @stdout = stdout
        end

        def call!
          validate_id!
          # Parse an authored target before loading the project overlay. The
          # general loader isolates broken siblings by warning and skipping;
          # validation targets one descriptor and must instead return its
          # diagnostic without an incidental stderr warning.
          Hive::Workflows::DescriptorParser.parse_file(descriptor_path) if descriptor_path
          workflow = Hive::WorkflowSelection.fetch!(@id, project_root: @project_root)
          validate_instruction_paths!(workflow)
          payload = payload_for(workflow)
          emit(payload)
          payload
        end

        def call = call!

        private

        def validate_id!
          raise UsageError.new("missing workflow id", value: @id) if @id.empty?
          return if WORKFLOW_ID_RE.match?(@id)

          raise UsageError.new(
            "invalid workflow id #{@id.inspect} (must match #{WORKFLOW_ID_RE.source})", value: @id
          )
        end

        def validate_instruction_paths!(workflow)
          workflow.each do |stage|
            next unless stage.instruction
            next if File.file?(stage.instruction) && File.readable?(stage.instruction)

            raise Hive::ConfigError,
                  "workflow descriptor #{descriptor_path || workflow.id.inspect} " \
                  "stage #{stage.name.inspect} references missing instruction #{stage.instruction.inspect}"
          end
        end

        def payload_for(workflow)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "valid" => true,
            "id" => workflow.id.to_s,
            "origin" => origin,
            "descriptor_path" => descriptor_path,
            "instruction_paths" => workflow.filter_map(&:instruction).uniq,
            "stages" => workflow.map { |stage| stage_payload(stage) },
            "automatic_edges" => automatic_edges(workflow),
            "human_outcomes" => human_outcomes(workflow),
            "diagnostics" => []
          }
        end

        def stage_payload(stage)
          {
            "name" => stage.name,
            "dir" => stage.dir,
            "kind" => stage.kind&.to_s,
            "state_file" => stage.state_file,
            "instruction_path" => stage.instruction,
            "input" => stage.input
          }
        end

        def automatic_edges(workflow)
          workflow.filter_map do |stage|
            target = workflow.next_stage_after(stage.name)
            next if stage.kind == :human || target.nil?

            { "from" => stage.name, "to" => target.name }
          end
        end

        def human_outcomes(workflow)
          workflow.flat_map do |stage|
            next [] unless stage.kind == :human

            stage.outcomes.values.map do |outcome|
              {
                "stage" => stage.name,
                "name" => outcome.name,
                "complete" => outcome.complete,
                "artifact" => outcome.artifact,
                "to" => outcome.to
              }
            end
          end
        end

        def workflows_dir
          @workflows_dir ||= Hive::Workflows::Loader.workflow_dir(@project_root)
        end

        def descriptor_path
          @descriptor_path ||= begin
            path = File.join(workflows_dir, "#{@id}.yml")
            File.file?(path) ? path : nil
          end
        end

        def origin
          return "authored" if descriptor_path
          return "built_in" if Hive::Workflows::Registry::WORKFLOWS.key?(@id.to_sym)

          "managed"
        end

        def emit(payload)
          if @json
            @stdout.puts JSON.generate(payload)
          else
            @stdout.puts "hive: workflow #{@id} is valid (#{origin})"
            @stdout.puts "  stages: #{payload.fetch('stages').map { |stage| stage.fetch('name') }.join(' -> ')}"
          end
        end
      end
    end
  end
end
