require "tmpdir"
require "hive/agent_profiles"
require "hive/commands/workflow/base"
require "hive/commands/workflow/configuration_resolver"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/runtime_policy"
require "hive/workflow_package/semantic_diff"
require "hive/workflow_package/validator"
require "hive/workflows/project"

module Hive
  module Commands
    class Workflow
      class Update < Base
        SCHEMA = "hive-workflow-update".freeze

        def initialize(name, project_root:, json: false, yes: false, allow_escalation: false,
                       dry_run: false, stdout: $stdout, stdin: $stdin, registry_client: nil, committer: nil,
                       mapping_overrides: [], input_bindings: [])
          super(project_root: project_root, json: json, stdout: stdout, stdin: stdin, yes: yes, committer: committer)
          @name = name.to_s.delete_prefix("honeycomb/")
          @allow_escalation = allow_escalation
          @dry_run = dry_run
          @registry_client = registry_client || Hive::WorkflowPackage::RegistryClient.new
          @mapping_overrides = mapping_overrides
          @input_bindings = input_bindings
        end

        def call!
          current = store.selected(@name, cfg: project_config)
          raise OwnershipError, "managed workflow #{@name.inspect} is not installed" unless current

          Dir.mktmpdir("hive-workflow-update-") do |candidate_root|
            candidate = @registry_client.fetch("honeycomb/#{@name}", destination: candidate_root)
            old_manifest = store.manifest(@name, current.fetch("source_commit"), current.fetch("manifest_digest"))
            previous_configuration = store.configuration(
              @name, current.fetch("configuration_digest"), cfg: project_config
            )
            validated = Hive::WorkflowPackage::Validator.validate!(
              candidate_root, expected_name: candidate.name,
              expected_manifest_digest: candidate.manifest_digest
            )
            diff = Hive::WorkflowPackage::SemanticDiff.compare(old_manifest, validated.manifest)
            resolver = ConfigurationResolver.new(
              validated: validated, resolution: candidate, cfg: project_config,
              mapping_overrides: @mapping_overrides, input_bindings: @input_bindings,
              previous: previous_configuration
            )
            same_generation = candidate.source_commit == current.fetch("source_commit")
            if same_generation && resolver.configuration.digest == current.fetch("configuration_digest")
              report = noop_payload(candidate, current, resolver)
              return emit(report, human_lines: [
                "hive: honeycomb/#{@name} is already current",
                *optional_input_disclosure(report.fetch("optional_inputs"))
              ])
            end
            configured = resolver.configuration.apply(validated.workflow, cfg: project_config)
            admit_runtime!(configured, candidate_root)
            report = payload("dry_run", current, candidate, diff, resolver)
            return emit(report, human_lines: human_diff(report)) if @dry_run

            human_diff(report).each { |line| @stdout.puts line } if interactive?

            unless confirmed?("Update honeycomb/#{@name} #{current.fetch('version')} -> #{candidate.version}?")
              return emit(payload("cancelled", current, candidate, diff, resolver),
                          human_lines: [ "hive: update cancelled; the previous selection is unchanged" ])
            end
            unless escalation_confirmed?(diff.escalation? || resolver.actor_policy_changed?)
              return emit(payload("cancelled", current, candidate, diff, resolver),
                          human_lines: [ "hive: escalation declined; the previous selection is unchanged" ])
            end

            store.place_generation(candidate_root, candidate)
            begin
              store.activate(
                candidate,
                configuration: resolver.configuration,
                cfg: project_config,
                expected_current: current,
                commit: -> { commit_state(@name, "updated") }
              )
            rescue StandardError
              store.cleanup_unreferenced(@name)
              raise
            end
            retained = store.cleanup_unreferenced(@name)
            commit_state(@name, "cleaned")
            Hive::Workflows::Project.reset!
            emit(payload("updated", current, candidate, diff, resolver).merge("retained_commits" => retained),
                 human_lines: human_diff(payload("updated", current, candidate, diff, resolver)))
          end
        end

        private

        def escalation_confirmed?(escalation)
          return true unless escalation
          return true if @allow_escalation
          unless interactive?
            raise ConsentRequired,
                  "security escalation requires separate --allow-escalation consent in addition to --yes"
          end

          @stdout.print "This update expands or weakens security capabilities. Allow escalation? [y/N] "
          %w[y yes].include?(@stdin.gets.to_s.strip.downcase)
        end

        def admit_runtime!(workflow, package_root)
          Dir.mktmpdir("hive-workflow-update-admission-") do |dir|
            task = File.join(dir, "task")
            FileUtils.mkdir_p(task)
            Hive::WorkflowPackage::RuntimePolicy.admit_workflow!(
              workflow, task_folder: task,
              policy_dir: File.join(dir, "policy"), package_root: package_root
            )
          end
        end

        def noop_payload(candidate, current, resolver)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => "already_current",
            "name" => @name,
            "from_commit" => candidate.source_commit,
            "to_commit" => candidate.source_commit,
            "manifest_digest" => candidate.manifest_digest,
            "diff" => nil,
            "configuration_digest" => current.fetch("configuration_digest"),
            "mappings" => resolver.mappings,
            "optional_inputs" => resolver.inputs
          }
        end

        def payload(status, current, candidate, diff, resolver)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => status,
            "name" => @name,
            "from_commit" => current.fetch("source_commit"),
            "to_commit" => candidate.source_commit,
            "manifest_digest" => candidate.manifest_digest,
            "diff" => diff.to_h.merge(
              "actor_policy_changed" => resolver.actor_policy_changed?,
              "input_bindings_changed" => resolver.input_bindings_changed?,
              "escalation" => diff.escalation? || resolver.actor_policy_changed?,
              "escalation_reasons" => (diff.to_h.fetch("escalation_reasons") +
                (resolver.actor_policy_changed? ? [ "actor_policy_redistribution" ] : [])).uniq
            ),
            "configuration_digest" => resolver.configuration.digest,
            "mappings" => resolver.mappings,
            "optional_inputs" => resolver.inputs
          }
        end

        def human_diff(report)
          diff = report.fetch("diff")
          [
            "hive: #{report.fetch('status')} honeycomb/#{@name} #{report.fetch('from_commit')} -> #{report.fetch('to_commit')}",
            "files: +#{diff.dig('files', 'added').length} -#{diff.dig('files', 'removed').length} ~#{diff.dig('files', 'modified').length}",
            "security escalation: #{diff.fetch('escalation')} #{diff.fetch('escalation_reasons').join(', ')}",
            "optional-input bindings changed: #{diff.fetch('input_bindings_changed')}",
            *optional_input_disclosure(report.fetch("optional_inputs"))
          ]
        end

        def envelope_schema = SCHEMA

        def project_config
          @project_config ||= Hive::Config.load(@project_root).merge("project_root" => @project_root)
        end
      end
    end
  end
end
