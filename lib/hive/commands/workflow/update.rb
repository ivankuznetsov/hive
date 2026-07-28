require "tmpdir"
require "hive/commands/workflow/base"
require "hive/commands/workflow/configuration_resolver"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/semantic_diff"

module Hive
  module Commands
    class Workflow
      class Update < Base
        SCHEMA = "hive-workflow-update".freeze

        def initialize(name, project_root:, json: false, yes: false, allow_escalation: false,
                       dry_run: false, stdout: $stdout, stdin: $stdin, registry_client: nil, committer: nil,
                       expected_current: nil, expected_configuration_digest: nil,
                       mapping_overrides: [], input_bindings: [])
          super(project_root: project_root, json: json, stdout: stdout, stdin: stdin, yes: yes, committer: committer)
          @name = name.to_s.delete_prefix("honeycomb/")
          @allow_escalation = allow_escalation
          @dry_run = dry_run
          @registry_client = registry_client || Hive::WorkflowPackage::RegistryClient.new
          @expected_current = expected_current
          @expected_configuration_digest = expected_configuration_digest
          @mapping_overrides = mapping_overrides
          @input_bindings = input_bindings
        end

        def call!
          current = store.selected(@name, cfg: project_config)
          raise OwnershipError, "managed workflow #{@name.inspect} is not installed" unless current
          if @expected_current && !same_selection?(current, @expected_current)
            raise Hive::ConcurrentRunError.new("managed workflow selection changed since the reviewed update preview")
          end

          Dir.mktmpdir("hive-workflow-update-") do |candidate_root|
            compatibility_candidate = workflow_compatibility.fetch(
              source: "honeycomb/#{@name}", destination: candidate_root,
              registry_client: @registry_client
            )
            candidate = compatibility_candidate.resolution
            old_manifest = store.manifest(@name, current.fetch("source_commit"), current.fetch("manifest_digest"))
            previous_configuration = store.configuration(
              @name, current.fetch("configuration_digest"), cfg: project_config
            )
            validated = compatibility_candidate.validated
            diff = Hive::WorkflowPackage::SemanticDiff.compare(old_manifest, validated.manifest)
            resolver = ConfigurationResolver.new(
              validated: validated, resolution: candidate, cfg: project_config,
              mapping_overrides: @mapping_overrides, input_bindings: @input_bindings,
              previous: previous_configuration
            )
            ensure_reviewed_configuration!(resolver)
            same_generation = candidate.source_commit == current.fetch("source_commit")
            if same_generation && resolver.configuration.digest == current.fetch("configuration_digest")
              report = noop_payload(candidate, current, resolver)
              return emit(report, human_lines: [
                "hive: honeycomb/#{@name} is already current",
                *optional_input_disclosure(report.fetch("optional_inputs"))
              ])
            end
            workflow_compatibility.admit_runtime!(
              validated.workflow, candidate_root, configuration: resolver.configuration
            )
            report = payload("dry_run", current, candidate, diff, resolver)
            return emit(report, human_lines: human_diff(report)) if @dry_run

            human_diff(report).each { |line| @stdout.puts line } if interactive?

            unless confirmed?("Update honeycomb/#{@name} #{current.fetch('version')} -> #{candidate.version}?")
              return emit(report.merge("status" => "cancelled"),
                          human_lines: [ "hive: update cancelled; the previous selection is unchanged" ])
            end
            unless escalation_confirmed?(report.dig("diff", "escalation"))
              return emit(report.merge("status" => "cancelled"),
                          human_lines: [ "hive: escalation declined; the previous selection is unchanged" ])
            end

            workflow_compatibility.activate!(
              candidate: compatibility_candidate,
              configuration: resolver.configuration,
              expected_current: current,
              commit: -> { commit_state(@name, "updated") },
              admit: false
            )
            warnings = []
            retained = post_commit_step(warnings, "unreferenced generation cleanup") do
              workflow_compatibility.cleanup_unreferenced(@name)
            end
            post_commit_step(warnings, "cleanup state commit") { commit_state(@name, "cleaned") } if retained
            post_commit_step(warnings, "workflow cache refresh") { workflow_compatibility.reset_cache! }
            report = report.merge("status" => "updated")
            report["retained_commits"] = retained if retained
            report["warnings"] = warnings unless warnings.empty?
            emit(report, human_lines: human_diff(report) + warning_lines(warnings))
          end
        end

        private

        def same_selection?(current, expected)
          current.fetch("source_commit") == expected.fetch("source_commit") &&
            current.fetch("manifest_digest") == expected.fetch("manifest_digest") &&
            current.fetch("configuration_digest") == expected.fetch("configuration_digest")
        end

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

        def ensure_reviewed_configuration!(resolver)
          return unless @expected_configuration_digest
          return if resolver.configuration.digest == @expected_configuration_digest

          raise Hive::ConcurrentRunError.new(
            "the workflow configuration changed since the reviewed update preview"
          )
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
          actor_policy_changed = resolver.actor_policy_changed?
          diff_data = diff.to_h
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => status,
            "name" => @name,
            "from_commit" => current.fetch("source_commit"),
            "to_commit" => candidate.source_commit,
            "manifest_digest" => candidate.manifest_digest,
            "diff" => diff_data.merge(
              "actor_policy_changed" => actor_policy_changed,
              "input_bindings_changed" => resolver.input_bindings_changed?,
              "escalation" => diff.escalation? || actor_policy_changed,
              "escalation_reasons" => (diff_data.fetch("escalation_reasons") +
                (actor_policy_changed ? [ "actor_policy_redistribution" ] : [])).uniq
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
      end
    end
  end
end
