require "hive/commands/workflow/base"
require "hive/workflows/project"
require "hive/workflows/registry"

module Hive
  module Commands
    class Workflow
      class Remove < Base
        SCHEMA = "hive-workflow-remove".freeze

        def initialize(name, project_root:, json: false, yes: false, stdout: $stdout, stdin: $stdin, committer: nil)
          super(project_root: project_root, json: json, stdout: stdout, stdin: stdin, yes: yes, committer: committer)
          @name = name.to_s.delete_prefix("honeycomb/")
        end

        def call!
          lock = store.selected(@name)
          raise ownership_error unless lock
          configured_default = Hive::Config.load(@project_root)["default_workflow"].to_s
          if configured_default == @name
            raise OwnershipError, "managed workflow #{@name.inspect} is the project default; choose another default before removal"
          end

          retained = store.task_references(@name).map { |reference| reference.fetch(:commit) }.uniq.sort
          versions = Dir.glob(File.join(store.workflows_dir, @name, "versions", "*")).map { |path| File.basename(path) }
          deletable = versions - retained
          cancelled = payload("cancelled", lock, retained, deletable)
          unless confirmed?("Remove honeycomb/#{@name} for new tasks?")
            return emit(cancelled, human_lines: [ "hive: remove cancelled; no project state changed" ])
          end

          store.remove_selection(@name, commit: -> { commit_state(@name, "removed") })
          retained = store.cleanup_unreferenced(@name)
          commit_state(@name, "cleaned") if deletable.any?
          Hive::Workflows::Project.reset!
          emit(payload("removed", lock, retained, deletable), human_lines: [
            "hive: removed honeycomb/#{@name}; retained #{retained.length} task-pinned generation(s)"
          ])
        end

        private

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
            "retained_commits" => retained,
            "deletable_commits" => deletable
          }
        end

        def envelope_schema = SCHEMA
      end
    end
  end
end
