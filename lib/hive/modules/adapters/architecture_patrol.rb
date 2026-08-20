require "time"
require "hive/commands/refactor_patrol"
require "hive/config"
require "hive/daemon/refactor_patrol_scheduler"
require "hive/modules/capability_context"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/modules/migration/shadow_comparator"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/decision_projection"
require "hive/refactor_patrol/scheduled_slice_producer"
require "hive/patrol/launch_budget"

module Hive
  module Modules
    module Adapters
      # Registered, declarative bridge from module occurrences to the existing
      # Architecture Patrol engine. Merge intake remains owned by the current
      # reconciler; this adapter consumes only its immutable manifest/job.
      class ArchitecturePatrol
        ENTRYPOINTS = {
          "architecture-patrol.setup" => "setup",
          "architecture-patrol.scheduled-discovery" => "scheduled-discovery",
          "architecture-patrol.merged-pr-discovery" => "merged-pr-discovery",
          "architecture-patrol.actions" => "actions"
        }.freeze

        def initialize(command_factory: nil, scheduler_factory: nil,
                       scheduled_producer_factory: nil,
                       state_store_factory: nil, shadow_sink: nil)
          @command_factory = command_factory || lambda do |project, options|
            Hive::Commands::RefactorPatrol.new(project, **options)
          end
          @scheduler_factory = scheduler_factory || lambda do |**options|
            Hive::Daemon::RefactorPatrolScheduler.new(**options)
          end
          @scheduled_producer_factory = scheduled_producer_factory || lambda do |entry, cfg|
            Hive::RefactorPatrol::ScheduledSliceProducer.new(entry: entry, cfg: cfg)
          end
          @state_store_factory = state_store_factory
          @shadow_sink = shadow_sink
        end

        def call(project:, hook_id:, event:, configuration:, **)
          validate_hook!(hook_id, event)
          context = CapabilityContext.new(configuration.grants)
          return setup(project, context, configuration, event) if hook_id == "setup"

          dispatch(project, hook_id, event, configuration, context)
        end

        private

        def setup(project, context, configuration, event)
          context.require_filesystem_write!(".hive-state/refactor_patrol/**")
          mode = migration_mode(project, configuration)
          return shadow(
            project, configuration, event, mode == :fenced ? "ownership_fenced" : "setup",
            comparable: false
          ) unless mode == :mutator

          state_store_for(project).ensure!
          0
        end

        def dispatch(project, hook_id, event, configuration, context)
          mode = migration_mode(project, configuration)
          return shadow(project, configuration, event, "ownership_fenced") if mode == :fenced
          if mode == :shadow &&
             event.dig("payload", "legacy_mutator_capture")
            return shadow(project, configuration, event, nil)
          end
          require_observation_capabilities!(context)
          cfg = effective_config(project)
          if hook_id == "scheduled-discovery"
            return shadow(project, configuration, event, "due") if mode == :shadow

            return dispatch_scheduled(project, cfg, configuration, context, event)
          end
          scheduler = @scheduler_factory.call(
            registry: -> { [ project ] }, config_loader: ->(_path) { cfg },
            dry_run: mode == :shadow || configuration.settings.fetch("dry_run"),
            migration_authority: mode == :mutator ? :module : :shadow,
            module_execution: {
              "module" => "architecture-patrol",
              "generation" =>
                configuration.generation.fetch("source_commit"),
              "configuration_digest" => configuration.digest
            }
          )
          candidate = select_candidate(scheduler.candidates(now: event_time(event)), hook_id, event)
          rationale = candidate ? "due" : "not_due"
          if mode == :shadow
            return shadow(project, configuration, event, rationale, candidate)
          end
          return 0 unless candidate

          require_mutation_capabilities!(context) unless configuration.settings.fetch("dry_run")
          run_candidate(project, cfg, configuration, context, scheduler, candidate, event)
        end

        def dispatch_scheduled(project, cfg, configuration, context, event)
          return 0 unless scheduled_budget(project, cfg, event).remaining_launches.positive?

          require_scheduled_mutation_capabilities!(context) unless configuration.settings.fetch("dry_run")
          producer = @scheduled_producer_factory.call(project, cfg)
          claim = producer.claim(now: event_time(event))
          return 0 unless claim

          options = {
            json: true, dry_run: configuration.settings.fetch("dry_run"),
            project_entry: project, config_loader: ->(_path) { cfg },
            capability_context: context, scheduled_slice: claim,
            module_execution: {
              "module" => "architecture-patrol",
              "generation" => configuration.generation.fetch("source_commit"),
              "configuration_digest" => configuration.digest
            }
          }
          envelope = @command_factory.call(project.fetch("name"), options).call
          successful = envelope.is_a?(Hash) && envelope["ok"] == true &&
                       envelope["review_complete"] == true &&
                       envelope["last_scanned_sha"] == claim.fetch("analysis_sha") &&
                       Array(envelope["review_errors"]).empty?
          if successful
            completed = producer.complete(
              claim_id: claim.fetch("id"), result: envelope,
              now: event_time(event)
            )
            return 1 unless completed

            scheduled_budget(project, cfg, event).clear_park!
            0
          else
            producer.release(claim_id: claim.fetch("id"), now: event_time(event))
            persist_scheduled_provider_hold(project, cfg, event, envelope)
            1
          end
        rescue StandardError
          producer&.release(claim_id: claim.fetch("id"), now: event_time(event)) if claim
          raise
        end

        def persist_scheduled_provider_hold(project, cfg, event, envelope)
          exhaustion = Array(envelope && envelope["review_errors"]).filter_map do |error|
            error.dig("details", "resource_exhaustion") if error.is_a?(Hash)
          end.find do |item|
            item.is_a?(Hash) && !%w[daily_agent_spawn_limit legacy_attribution_ambiguous]
              .include?(item["reason"].to_s)
          end
          return unless exhaustion

          now = event_time(event)
          retry_at = begin
            Time.iso8601(exhaustion["retry_at"] || exhaustion["retry_after"])
          rescue ArgumentError, TypeError
            now + (exhaustion["retry_after_sec"] || 3600).to_i.clamp(1, 86_400)
          end
          scheduled_budget(project, cfg, event).park!(
            retry_at: retry_at, reason: exhaustion.fetch("reason").to_s
          )
        end

        def scheduled_budget(project, cfg, event)
          now = event_time(event)
          Hive::Patrol::LaunchBudget.new(
            project.fetch("path"), cfg: cfg,
            project_id: project.fetch("project_id"),
            project_name: project.fetch("name"), engine: :architecture,
            clock: -> { now }
          )
        end

        def state_store_for(project)
          return @state_store_factory.call(project.fetch("path")) if @state_store_factory

          Hive::RefactorPatrol::StateStore.new(
            project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
          )
        end

        def run_candidate(project, cfg, configuration, context, scheduler, candidate, event)
          reserved = scheduler.reserve(candidate, now: event_time(event))
          options = {
            json: true, dry_run: configuration.settings.fetch("dry_run"),
            job_manifest: reserved.fetch(:manifest_path), project_entry: project,
            config_loader: ->(_path) { cfg }, capability_context: context,
            occurrence_id:
              reserved.dig(:dispatch_token, :occurrence_id),
            module_execution: {
              "module" => "architecture-patrol",
              "generation" =>
                configuration.generation.fetch("source_commit"),
              "configuration_digest" => configuration.digest
            }
          }
          options[:actions] = true if reserved.fetch(:action_phase, :discovery).to_sym == :action
          envelope = @command_factory.call(project.fetch("name"), options).call
          result = scheduler.complete(
            dispatch_token: reserved.fetch(:dispatch_token),
            exit_code: envelope.is_a?(Hash) && envelope["ok"] == false ? 1 : 0,
            envelope: envelope, now: event_time(event)
          )
          result.fetch(:status) == :retry ? 1 : 0
        rescue StandardError
          scheduler.cancel(reserved, reason: "module_hook_error", now: event_time(event)) if reserved
          raise
        end

        def select_candidate(candidates, hook_id, event)
          phase = hook_id == "actions" ? :action : :discovery
          matches = Array(candidates).select do |candidate|
            candidate.fetch(:action_phase, :discovery).to_sym == phase
          end
          return matches.first unless hook_id == "merged-pr-discovery"

          job_id = event.dig("payload", "job_id").to_s
          match = matches.find { |candidate| candidate.fetch(:job_id).to_s == job_id }
          return unless match

          expected = event.dig("payload", "manifest_digest").to_s
          actual = match.dig(:source, "manifest_checksum").to_s
          unless !expected.empty? && expected == actual
            raise Hive::ConfigError, "Architecture Patrol merged event manifest identity does not match"
          end
          match
        end

        def require_observation_capabilities!(context)
          context.require_filesystem_read!("repository")
          context.require_external_command!("git")
        end

        def require_mutation_capabilities!(context)
          context.require_repository_write!
          context.require_filesystem_write!(".hive-state/refactor_patrol/**")
          context.require_github_mutation!("pull_requests")
          context.require_external_command!("gh")
          context.require_network_host!("api.github.com")
        end

        def require_scheduled_mutation_capabilities!(context)
          context.require_repository_write!
          context.require_filesystem_write!(".hive-state/refactor_patrol/**")
        end

        def effective_config(project)
          Hive::Modules::Migration::Patrols.reviewed_config(
            project.fetch("path"), "architecture-patrol",
            hive_state_path: project["hive_state_path"]
          )
        end

        def event_time(event) = Time.iso8601(event.fetch("occurred_at"))
        def migration_mode(project, configuration)
          Hive::Modules::Migration::Patrols.module_mode(
            project.fetch("path"), "architecture-patrol",
            configured_shadow: configuration.settings.fetch("shadow_mode"),
            hive_state_path: project["hive_state_path"]
          )
        end

        def shadow(project, configuration, event, rationale, candidate = nil, comparable: true)
          record = {
            "module" => "architecture-patrol", "hook" => event.fetch("event_name"),
            "event_id" => event.fetch("event_id"), "rationale" => rationale,
            "job_id" => candidate && candidate[:job_id],
            "phase" => candidate && candidate.fetch(:action_phase, :discovery).to_s,
            "configuration_digest" => configuration.digest
          }
          if @shadow_sink
            @shadow_sink.call(record)
          else
            capture = legacy_capture(event)
            receipts = capture ? occurrence_receipts(project, capture) : []
            projection = if capture
              Hive::RefactorPatrol::DecisionProjection.project(
                capture.selection_input
              )
            elsif candidate
              input =
                Hive::RefactorPatrol::DecisionProjection.candidate_input(
                  job_id: record.fetch("job_id"),
                  phase: record.fetch("phase")
                )
              Hive::RefactorPatrol::DecisionProjection.project(input)
            else
              Hive::Modules::Migration::PatrolDecisionProjection.build(
                module_name: "architecture-patrol",
                rationale: "not_due"
              )
            end
            shadow_comparator(project).record!(
              module_name: "architecture-patrol",
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
              comparable: comparable && !capture.nil?
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
          unless value.module_name == "architecture-patrol" &&
                 value.project.fetch("project_id") == event.fetch("project_id") &&
                 value.project.fetch("name") == event.fetch("project")
            raise Hive::ConfigError,
                  "Architecture Patrol legacy shadow capture is malformed"
          end
          value
        rescue Hive::ConfigError, KeyError
          raise Hive::ConfigError,
                "Architecture Patrol legacy shadow capture is malformed"
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
                  "Architecture Patrol occurrence receipt index exceeds its bound"
          end
          page.records.select do |receipt|
            receipt.intent.module_name == "architecture-patrol"
          end
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
            "setup" => "project.registered", "scheduled-discovery" => "schedule",
            "merged-pr-discovery" => "pull_request.merged", "actions" => "schedule"
          }.fetch(hook_id) do
            raise Hive::ConfigError, "unknown Architecture Patrol module hook #{hook_id.inspect}"
          end
          return if event.fetch("event_name") == expected

          raise Hive::ConfigError,
                "Architecture Patrol module hook #{hook_id.inspect} cannot handle #{event.fetch('event_name').inspect}"
        end
      end
    end
  end
end
