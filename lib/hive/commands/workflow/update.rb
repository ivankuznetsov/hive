require "tmpdir"
require "hive/agent_profiles"
require "hive/commands/workflow/base"
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
                       dry_run: false, stdout: $stdout, stdin: $stdin, registry_client: nil, committer: nil)
          super(project_root: project_root, json: json, stdout: stdout, stdin: stdin, yes: yes, committer: committer)
          @name = name.to_s.delete_prefix("honeycomb/")
          @allow_escalation = allow_escalation
          @dry_run = dry_run
          @registry_client = registry_client || Hive::WorkflowPackage::RegistryClient.new
        end

        def call!
          current = store.selected(@name)
          raise OwnershipError, "managed workflow #{@name.inspect} is not installed" unless current

          Dir.mktmpdir("hive-workflow-update-") do |candidate_root|
            candidate = @registry_client.fetch("honeycomb/#{@name}", destination: candidate_root)
            if candidate.source_commit == current.fetch("source_commit")
              return emit(noop_payload(candidate), human_lines: [ "hive: honeycomb/#{@name} is already current" ])
            end
            old_manifest = store.manifest(@name, current.fetch("source_commit"), current.fetch("manifest_digest"))
            new_manifest = Hive::WorkflowPackage::Manifest.load(File.join(candidate_root, "manifest.json"))
            diff = Hive::WorkflowPackage::SemanticDiff.compare(old_manifest, new_manifest)
            admit_runtime!(candidate, candidate_root)
            report = payload("dry_run", current, candidate, diff)
            return emit(report, human_lines: human_diff(report)) if @dry_run

            unless confirmed?("Update honeycomb/#{@name} #{current.fetch('version')} -> #{candidate.version}?")
              return emit(payload("cancelled", current, candidate, diff),
                          human_lines: [ "hive: update cancelled; the previous selection is unchanged" ])
            end
            unless escalation_confirmed?(diff)
              return emit(payload("cancelled", current, candidate, diff),
                          human_lines: [ "hive: escalation declined; the previous selection is unchanged" ])
            end

            store.place_generation(candidate_root, candidate)
            begin
              store.activate(
                candidate,
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
            emit(payload("updated", current, candidate, diff).merge("retained_commits" => retained),
                 human_lines: human_diff(payload("updated", current, candidate, diff)))
          end
        end

        private

        def escalation_confirmed?(diff)
          return true unless diff.escalation?
          return true if @allow_escalation
          unless interactive?
            raise ConsentRequired,
                  "security escalation requires separate --allow-escalation consent in addition to --yes"
          end

          @stdout.print "This update expands or weakens security capabilities. Allow escalation? [y/N] "
          %w[y yes].include?(@stdin.gets.to_s.strip.downcase)
        end

        def admit_runtime!(candidate, candidate_root)
          Dir.mktmpdir("hive-workflow-update-admission-") do |dir|
            task = File.join(dir, "task")
            FileUtils.mkdir_p(task)
            validated = Hive::WorkflowPackage::Validator.validate!(
              candidate_root, expected_name: candidate.name,
              expected_manifest_digest: candidate.manifest_digest
            )
            Hive::WorkflowPackage::RuntimePolicy.admit_workflow!(
              validated.workflow, candidate.permissions, task_folder: task,
              policy_dir: File.join(dir, "policy")
            )
          end
        end

        def noop_payload(candidate)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => "already_current",
            "name" => @name,
            "from_commit" => candidate.source_commit,
            "to_commit" => candidate.source_commit,
            "manifest_digest" => candidate.manifest_digest,
            "diff" => nil
          }
        end

        def payload(status, current, candidate, diff)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => status,
            "name" => @name,
            "from_commit" => current.fetch("source_commit"),
            "to_commit" => candidate.source_commit,
            "manifest_digest" => candidate.manifest_digest,
            "diff" => diff.to_h
          }
        end

        def human_diff(report)
          diff = report.fetch("diff")
          [
            "hive: #{report.fetch('status')} honeycomb/#{@name} #{report.fetch('from_commit')} -> #{report.fetch('to_commit')}",
            "files: +#{diff.dig('files', 'added').length} -#{diff.dig('files', 'removed').length} ~#{diff.dig('files', 'modified').length}",
            "security escalation: #{diff.fetch('escalation')} #{diff.fetch('escalation_reasons').join(', ')}"
          ]
        end

        def envelope_schema = SCHEMA
      end
    end
  end
end
