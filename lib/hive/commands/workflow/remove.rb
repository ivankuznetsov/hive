require "hive/commands/workflow/base"
require "hive/workflows/registry"

module Hive
  module Commands
    class Workflow
      class Remove < Base
        SCHEMA = "hive-workflow-remove".freeze

        def initialize(name, project_root:, json: false, yes: false, dry_run: false,
                       stdout: $stdout, stdin: $stdin, committer: nil, expected_current: nil)
          super(project_root: project_root, json: json, stdout: stdout, stdin: stdin, yes: yes, committer: committer)
          @name = name.to_s.delete_prefix("honeycomb/")
          @dry_run = dry_run
          @expected_current = expected_current
        end

        def call!
          lock = store.selected(@name)
          raise ownership_error unless lock
          if @expected_current && !same_selection?(lock, @expected_current)
            raise Hive::ConcurrentRunError.new("managed workflow selection changed since the reviewed removal preview")
          end
          configured_default = project_config["default_workflow"].to_s
          if configured_default == @name
            raise OwnershipError, "managed workflow #{@name.inspect} is the project default; choose another default before removal"
          end

          retained = store.task_references(@name).map { |reference| reference.fetch(:commit) }.uniq.sort
          versions = Dir.glob(File.join(store.workflows_dir, @name, "versions", "*")).map { |path| File.basename(path) }
          deletable = versions - retained
          if @dry_run
            return emit(payload("dry_run", lock, retained, deletable), human_lines: [
              "hive: would remove honeycomb/#{@name}; retain #{retained.length}, delete #{deletable.length} generation(s)"
            ])
          end
          cancelled = payload("cancelled", lock, retained, deletable)
          unless confirmed?("Remove honeycomb/#{@name} for new tasks?")
            return emit(cancelled, human_lines: [ "hive: remove cancelled; no project state changed" ])
          end

          workflow_compatibility.remove_selection!(
            name: @name, expected_current: lock,
            commit: -> { commit_state(@name, "removed") }
          )
          warnings = []
          cleaned = post_commit_step(warnings, "unreferenced generation cleanup") do
            workflow_compatibility.cleanup_unreferenced(@name)
          end
          retained = cleaned if cleaned
          if cleaned && deletable.any?
            post_commit_step(warnings, "cleanup state commit") { commit_state(@name, "cleaned") }
          end
          post_commit_step(warnings, "workflow cache refresh") { workflow_compatibility.reset_cache! }
          report = payload("removed", lock, retained, deletable)
          report["warnings"] = warnings unless warnings.empty?
          emit(report, human_lines: [
            "hive: removed honeycomb/#{@name}; retained #{retained.length} task-pinned generation(s)",
            *warning_lines(warnings)
          ])
        end

        private

        def same_selection?(current, expected)
          current.fetch("source_commit") == expected.fetch("source_commit") &&
            current.fetch("manifest_digest") == expected.fetch("manifest_digest") &&
            current.fetch("configuration_digest") == expected.fetch("configuration_digest")
        end

        def ownership_error
          if Hive::Workflows::Registry::WORKFLOWS.key?(@name.to_sym) || File.file?(File.join(store.workflows_dir, "#{@name}.yml"))
            OwnershipError.new("workflow #{@name.inspect} is not Hive-managed and cannot be removed by this command")
          else
            OwnershipError.new("managed workflow #{@name.inspect} is not installed")
          end
        end

        def payload(status, lock, retained, deletable)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => status,
            "name" => @name,
            "source_commit" => lock.fetch("source_commit"),
            "manifest_digest" => lock.fetch("manifest_digest"),
            "configuration_digest" => lock.fetch("configuration_digest"),
            "retained_commits" => retained,
            "deletable_commits" => deletable
          }
        end

        def envelope_schema = SCHEMA
      end
    end
  end
end
