require "hive/commands/module/base"
require "hive/attempts/store"
require "hive/modules/dry_run"

module Hive
  module Commands
    class Module
      class DryRun < Base
        def initialize(name, event_name:, hook_id: nil, schedule: nil, occurred_at: nil,
                       evaluator: nil, project_identity: nil, **options)
          super(**{ yes: false, dry_run: false, receipt: nil }.merge(options))
          @name = name.to_s
          @event_name = event_name.to_s
          @hook_id = hook_id
          @schedule = schedule
          @occurred_at = occurred_at
          @evaluator = evaluator
          @project_identity = project_identity
        end

        def call!
          identity = @project_identity || registered_identity
          evaluator = @evaluator || Hive::Modules::DryRun.new(
            store: store,
            attempt_store: Hive::Attempts::Store.new(create_directories: false),
            project_id: identity.fetch("project_id"),
            project: identity.fetch("name")
          )
          result = evaluator.evaluate(
            module_name: @name, hook_id: @hook_id, event_name: @event_name,
            occurred_at: @occurred_at || Time.now.utc, schedule: @schedule
          )
          payload = {
            "schema" => "hive-module-dry-run",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-module-dry-run"),
            "ok" => true, "module" => @name, **result
          }
          lines = result.fetch("decisions").map do |row|
            "#{row.fetch('hook')} #{row.fetch('outcome')} reason=#{row.fetch('reason')}"
          end
          emit(payload, human_lines: lines)
        end

        private

        def registered_identity
          root = File.realpath(@project_root)
          entry = Hive::Config.registered_projects.find do |candidate|
            File.realpath(candidate.fetch("path")) == root
          rescue SystemCallError
            false
          end
          raise Hive::ConfigError, "module dry-run requires a registered project identity" unless entry
          entry
        end

        def envelope_schema = "hive-module-dry-run"
      end
    end
  end
end
