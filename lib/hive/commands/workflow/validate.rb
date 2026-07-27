require "json"
require "hive/config"
require "hive/workflows/descriptor_parser"
require "hive/workflows/registry"
require "hive/workflow_package/managed_store"

module Hive
  module Commands
    class Workflow
      # Strictly read-only validation through direct authored, built-in, and
      # managed-store lookups. It deliberately bypasses production selection
      # reconciliation because even lock creation or journal repair would
      # violate this command's no-write contract.
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
          workflow = resolve_read_only!
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
          @workflows_dir ||= begin
            source_path, data = Hive::Config.read_project_config(@project_root)
            data = Hive::Config.normalize_legacy_project_config(
              data, source_path, emit_warning: false
            )
            hive_state_path = data["hive_state_path"]
            unless hive_state_path.is_a?(String)
              hive_state_path = Hive::Config::DEFAULTS.fetch("hive_state_path")
            end
            File.join(File.expand_path(hive_state_path, @project_root), "workflows")
          end
        end

        def resolve_read_only!
          if descriptor_path
            workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
            if Hive::Workflows::Registry::WORKFLOWS.key?(workflow.id)
              raise Hive::ConfigError,
                    "workflow descriptor #{descriptor_path} collides with registered workflow #{workflow.id.inspect}"
            end
            @origin = "authored"
            return workflow
          end

          id = @id.to_sym
          if Hive::Workflows::Registry::WORKFLOWS.key?(id)
            @origin = "built_in"
            return Hive::Workflows::Registry.fetch(id)
          end

          store = Hive::WorkflowPackage::ManagedStore.new(File.dirname(workflows_dir))
          selection = store.selected_read_only(@id)
          if selection
            @origin = "managed"
            return store.workflow(
              @id, selection.fetch("source_commit"), selection.fetch("manifest_digest"),
              configuration_digest: selection.fetch("configuration_digest"),
              verify_profiles: false
            )
          end

          raise Hive::Workflows::UnknownWorkflow.new(
            "unknown workflow #{@id.inspect}; valid workflows: #{read_only_workflow_ids.join(', ')}",
            value: @id, valid: read_only_workflow_ids
          )
        end

        def read_only_workflow_ids
          authored = Dir.glob(File.join(workflows_dir, "*.yml")).map do |path|
            File.basename(path, ".yml")
          end
          managed = Dir.glob(
            File.join(workflows_dir, "*", Hive::WorkflowPackage::ManagedStore::LOCK_FILE)
          ).map { |path| File.basename(File.dirname(path)) }
          (Hive::Workflows::Registry::WORKFLOWS.keys.map(&:to_s) + authored + managed).uniq.sort
        end

        def descriptor_path
          @descriptor_path ||= begin
            path = File.join(workflows_dir, "#{@id}.yml")
            File.file?(path) ? path : nil
          end
        end

        def origin
          return @origin if @origin
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
