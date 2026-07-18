require "tmpdir"
require "hive/agent_profiles"
require "hive/commands/workflow/base"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/runtime_policy"
require "hive/workflow_package/validator"
require "hive/workflows/project"

module Hive
  module Commands
    class Workflow
      class Install < Base
        SCHEMA = "hive-workflow-install".freeze

        def initialize(source, project_root:, json: false, yes: false, dry_run: false, stdout: $stdout, stdin: $stdin,
                       registry_client: nil, committer: nil)
          super(project_root: project_root, json: json, stdout: stdout, stdin: stdin, yes: yes, committer: committer)
          @source = source
          @dry_run = dry_run
          @registry_client = registry_client || Hive::WorkflowPackage::RegistryClient.new
        end

        def call!
          Dir.mktmpdir("hive-workflow-install-") do |package_root|
            resolution = @registry_client.fetch(@source, destination: package_root)
            current = store.selected(resolution.name)
            if current && current.fetch("source_commit") == resolution.source_commit
              return emit(payload(resolution, "already_installed"), human_lines: [
                "hive: honeycomb/#{resolution.name} is already installed at #{resolution.source_commit}"
              ])
            end
            if current
              raise UpdateRequired,
                    "honeycomb/#{resolution.name} is already managed at another commit; use `hive workflow update #{resolution.name}`"
            end

            admit_runtime!(resolution, package_root)
            if @dry_run
              return emit(payload(resolution, "dry_run"), human_lines: human_disclosure(resolution, verb: "would install"))
            end
            disclosure = payload(resolution, "cancelled")
            unless confirmed?("Install honeycomb/#{resolution.name}@#{resolution.version} with the disclosed policy?")
              return emit(disclosure, human_lines: [ "hive: install cancelled; no project state changed" ])
            end

            store.place_generation(package_root, resolution)
            begin
              store.activate(resolution, commit: -> { commit_state(resolution.name, "installed") })
            rescue StandardError
              store.cleanup_unreferenced(resolution.name)
              raise
            end
            Hive::Workflows::Project.reset!
            emit(payload(resolution, "installed"), human_lines: human_disclosure(resolution))
          end
        end

        private

        def admit_runtime!(resolution, package_root)
          Dir.mktmpdir("hive-workflow-admission-") do |admission_root|
            task_folder = File.join(admission_root, "task")
            FileUtils.mkdir_p(task_folder)
            validated = Hive::WorkflowPackage::Validator.validate!(
              package_root, expected_name: resolution.name,
              expected_manifest_digest: resolution.manifest_digest
            )
            Hive::WorkflowPackage::RuntimePolicy.admit_workflow!(
              validated.workflow, resolution.permissions,
              task_folder: task_folder,
              policy_dir: File.join(admission_root, "policy")
            )
          end
        end

        def payload(resolution, status)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => status,
            "name" => resolution.name,
            "version" => resolution.version,
            "catalog_commit" => resolution.catalog_commit,
            "source_commit" => resolution.source_commit,
            "manifest_digest" => resolution.manifest_digest,
            "permissions" => resolution.permissions
          }
        end

        def human_disclosure(resolution, verb: "installed")
          permissions = resolution.permissions
          [
            "hive: #{verb} honeycomb/#{resolution.name}@#{resolution.version}",
            "source: #{resolution.source_commit} manifest: #{resolution.manifest_digest}",
            "tools: #{Array(permissions['tools']).join(', ')}; deny: #{Array(permissions['deny']).join(', ')}",
            "commands: #{Array(permissions['commands']).join(', ')}; domains: #{Array(permissions['domains']).join(', ')}"
          ]
        end

        def envelope_schema = SCHEMA
      end
    end
  end
end
