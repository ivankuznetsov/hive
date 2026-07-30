require "hive/commands/patrol"
require "hive/config"
require "hive/daemon/patrol_scheduler"
require "hive/modules/capability_context"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/modules/migration/shadow_comparator"
require "hive/patrol/state_store"
require "hive/patrol/decision_projection"

module Hive
  module Modules
    module Adapters
      class Patrol
        ENTRYPOINTS = {
          "patrol.setup" => "setup",
          "patrol.scheduled-scan" => "scheduled-scan",
          "patrol.task-completed" => "task-completed"
        }.freeze

        def initialize(command_factory: nil, scheduler_factory: nil, shadow_sink: nil)
          @command_factory = command_factory || lambda do |project, options|
            Hive::Commands::Patrol.new(project, **options)
          end
          @scheduler_factory = scheduler_factory || ->(**options) { Hive::Daemon::PatrolScheduler.new(**options) }
          @shadow_sink = shadow_sink
        end

        def call(project:, hook_id:, event:, configuration:, **)
          validate_hook!(hook_id, event)
          context = CapabilityContext.new(configuration.grants)
          case hook_id
          when "setup" then setup(project, context, configuration, event)
          when "scheduled-scan"
            scheduled_scan(
              project, context, effective_config(project, configuration), configuration, event
            )
          when "task-completed"
            task_completed(
              project, context, effective_config(project, configuration), configuration, event
            )
          end
        end

        private

        def setup(project, context, configuration, event)
          context.require_filesystem_write!(".hive-state/patrol/**")
          mode = migration_mode(project, configuration)
          return shadow(project, configuration, event, mode == :fenced ? "ownership_fenced" : "setup", comparable: false) unless mode == :mutator

          Hive::Patrol::StateStore.new(
            project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
          ).ensure!
          0
        end

        def scheduled_scan(project, context, cfg, configuration, event)
          mode = migration_mode(project, configuration)
          return shadow(project, configuration, event, "ownership_fenced") if mode == :fenced
          if mode == :shadow &&
             event.dig("payload", "legacy_mutator_capture")
            return shadow(project, configuration, event, nil)
          end
          context.require_filesystem_read!("repository")
          context.require_external_command!("git")
          scheduler = @scheduler_factory.call(
            registry: -> { [ project ] }, config_loader: ->(_path) { cfg },
            migration_authority: mode == :mutator ? :module : :shadow
          )
          candidate = scheduler.candidates(now: Time.iso8601(event.fetch("occurred_at"))).first
          unless mode == :mutator
            rationale = candidate ? "due" : "not_due"
            return shadow(project, configuration, event, rationale)
          end
          return 0 unless candidate

          run_cycle(project, context, cfg, configuration, event)
        end

        def task_completed(project, context, cfg, configuration, event)
          return shadow(project, configuration, event, "no_match", comparable: false) unless task_matches?(configuration, event)
          mode = migration_mode(project, configuration)
          return shadow(
            project, configuration, event, mode == :fenced ? "ownership_fenced" : "matched",
            comparable: false
          ) unless mode == :mutator

          context.require_filesystem_read!("repository")
          context.require_external_command!("git")
          run_cycle(project, context, cfg, configuration, event)
        end

        def run_cycle(project, context, cfg, configuration, event)
          dry_run = configuration.settings.fetch("dry_run")
          unless dry_run
            context.require_repository_write!
            context.require_filesystem_write!(".hive-state/patrol/**")
            context.require_github_mutation!("pull_requests")
            context.require_external_command!("gh")
            context.require_network_host!("api.github.com")
          end
          result = @command_factory.call(
            project.fetch("name"),
            {
              json: true, dry_run: dry_run, project_entry: project,
              config_loader: ->(_path) { cfg }, capability_context: context,
              module_execution: module_execution(configuration),
              capture: module_capture(project, event),
              migration_authority: :module
            }
          ).call
          result.is_a?(Hash) && result["ok"] == false ? 1 : 0
        end

        def effective_config(project, configuration)
          current = Hive::Modules::Migration::Patrols.reviewed_config(
            project.fetch("path"), "patrol", hive_state_path: project["hive_state_path"]
          )
          settings = configuration.settings
          overrides = {
            "trigger" => settings.fetch("trigger"),
            "poll_interval_sec" => settings.fetch("poll_interval_sec")
          }
          Hive::Config.deep_merge(current, "patrol" => overrides)
        end

        def module_execution(configuration)
          {
            "module" => "patrol",
            "generation" =>
              configuration.generation.fetch("source_commit"),
            "configuration_digest" => configuration.digest
          }
        end

        def task_matches?(configuration, event)
          workflow = event.dig("payload", "workflow").to_s
          filters = configuration.settings.fetch("task_completed_workflows").split(",").map(&:strip)
          filters.include?("*") || filters.include?(workflow)
        end

        def migration_mode(project, configuration)
          Hive::Modules::Migration::Patrols.module_mode(
            project.fetch("path"), "patrol",
            configured_shadow: configuration.settings.fetch("shadow_mode"),
            hive_state_path: project["hive_state_path"]
          )
        end

        def shadow(project, configuration, event, rationale, comparable: true)
          record = {
            "module" => "patrol", "hook" => event.fetch("event_name"),
            "event_id" => event.fetch("event_id"), "rationale" => rationale,
            "configuration_digest" => configuration.digest
          }
          if @shadow_sink
            @shadow_sink.call(record)
          else
            capture = legacy_capture(event)
            receipts = capture ? occurrence_receipts(project, capture) : []
            projection = if capture
              Hive::Patrol::DecisionProjection.project(
                capture.selection_input
              )
            else
              Hive::Modules::Migration::PatrolDecisionProjection.build(
                module_name: "patrol",
                rationale:
                  %w[due disabled].include?(rationale) ?
                    rationale : "not_due"
              )
            end
            shadow_comparator(project).record!(
              module_name: "patrol",
              trigger: capture ? capture.trigger : shadow_trigger(event),
              legacy_capture: capture,
              module_projection: projection,
              legacy_effects: receipts.reject do |receipt|
                receipt.intent.authority == "shadow"
              end,
              module_effects: receipts.select do |receipt|
                receipt.intent.authority == "shadow"
              end,
              configuration_digest: configuration.digest,
              occurred_at: event.fetch("occurred_at"),
              comparable:
                comparable && !capture.nil? &&
                %w[due not_due disabled].include?(
                  projection.rationale
                )
            )
          end
          0
        end

        def shadow_comparator(project)
          state = project["hive_state_path"] || File.join(project.fetch("path"), ".hive-state")
          Hive::Modules::Migration::ShadowComparator.new(
            root: File.join(state, "module-runtime", "migration", "shadow")
          )
        end

        def shadow_trigger(event)
          {
            "kind" => "module_event",
            "id" => event.fetch("event_id"),
            "event_name" => event.fetch("event_name"),
            "occurred_at" => event.fetch("occurred_at")
          }
        end

        def legacy_capture(event)
          capture = event.dig("payload", "legacy_mutator_capture")
          return nil if capture.nil?

          value = Hive::Modules::Migration::PatrolCapture.from_h(capture)
          unless value.module_name == "patrol" &&
                 value.project.fetch("project_id") == event.fetch("project_id") &&
                 value.project.fetch("name") == event.fetch("project")
            raise Hive::ConfigError, "Patrol legacy shadow capture is malformed"
          end
          value
        rescue Hive::ConfigError, KeyError
          raise Hive::ConfigError, "Patrol legacy shadow capture is malformed"
        end

        def occurrence_receipts(project, capture)
          page = evidence_store(project).receipts_for_occurrence(
            capture.occurrence_id,
            limit:
              Hive::Modules::Migration::PatrolEvidence::
                MAX_EFFECTS_PER_OCCURRENCE
          )
          if page.next_cursor
            raise Hive::ConfigError,
                  "Patrol occurrence receipt index exceeds its bound"
          end
          page.records.select do |receipt|
            receipt.intent.module_name == "patrol"
          end
        end

        def module_capture(project, event)
          snapshot = Hive::Modules::Migration::Patrols.ownership_snapshot(
            project.fetch("path"), "patrol",
            hive_state_path: project["hive_state_path"]
          )
          unless snapshot["owner"] == "module" &&
                 snapshot["admission"] == true &&
                 snapshot["epoch"].to_i.positive?
            raise Hive::ConfigError,
                  "Patrol module occurrence lost mutation ownership"
          end

          selection_input =
            Hive::Patrol::DecisionProjection.module_event_input(
              event.fetch("event_id")
            )
          Hive::Modules::Migration::PatrolCapture.build(
            module_name: "patrol",
            project: {
              "project_id" => project.fetch("project_id"),
              "name" => project.fetch("name"),
              "repository" => project["repository_identity"]
            },
            trigger: {
              "kind" => "module_event",
              "id" => event.fetch("event_id"),
              "event_name" => event.fetch("event_name"),
              "occurred_at" => event.fetch("occurred_at")
            },
            reservation: {
              "kind" => "module_hook",
              "id" => event.fetch("event_id"),
              "window_started_at" => event.fetch("occurred_at"),
              "attempt_generation" => 1
            },
            owner: "module",
            owner_epoch: snapshot.fetch("epoch"),
            selection_input: selection_input,
            selection:
              Hive::Patrol::DecisionProjection.project(
                selection_input
              ),
            outcome_class: nil,
            outcome: nil,
            occurred_at: event.fetch("occurred_at"),
            recorded_at: event.fetch("recorded_at", event.fetch("occurred_at"))
          )
        end

        def evidence_store(project)
          state = project["hive_state_path"] ||
                  File.join(project.fetch("path"), ".hive-state")
          Hive::Modules::Migration::EvidenceStore.new(
            root: File.join(
              state, "module-runtime", "migration", "patrol-evidence"
            )
          )
        end

        def validate_hook!(hook_id, event)
          expected = {
            "setup" => "project.registered", "scheduled-scan" => "schedule",
            "task-completed" => "task.completed"
          }.fetch(hook_id) { raise Hive::ConfigError, "unknown Patrol module hook #{hook_id.inspect}" }
          return if event.fetch("event_name") == expected
          raise Hive::ConfigError, "Patrol module hook #{hook_id.inspect} cannot handle #{event.fetch('event_name').inspect}"
        end
      end
    end
  end
end
