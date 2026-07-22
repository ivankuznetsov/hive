require "time"
require "hive/commands/refactor_patrol"
require "hive/config"
require "hive/daemon/refactor_patrol_scheduler"
require "hive/modules/capability_context"
require "hive/refactor_patrol/state_store"

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
                       state_store_factory: nil, shadow_sink: ->(_record) { })
          @command_factory = command_factory || lambda do |project, options|
            Hive::Commands::RefactorPatrol.new(project, **options)
          end
          @scheduler_factory = scheduler_factory || lambda do |**options|
            Hive::Daemon::RefactorPatrolScheduler.new(**options)
          end
          @state_store_factory = state_store_factory || ->(root) { Hive::RefactorPatrol::StateStore.new(root) }
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
          return shadow(configuration, event, "setup") if shadow?(configuration)

          @state_store_factory.call(project.fetch("path")).ensure!
          0
        end

        def dispatch(project, hook_id, event, configuration, context)
          require_observation_capabilities!(context)
          cfg = effective_config(project)
          scheduler = @scheduler_factory.call(
            registry: -> { [ project ] }, config_loader: ->(_path) { cfg },
            dry_run: shadow?(configuration) || configuration.settings.fetch("dry_run")
          )
          candidate = select_candidate(scheduler.candidates(now: event_time(event)), hook_id, event)
          rationale = candidate ? "due" : "not_due"
          return shadow(configuration, event, rationale, candidate) if shadow?(configuration)
          return 0 unless candidate

          require_mutation_capabilities!(context) unless configuration.settings.fetch("dry_run")
          run_candidate(project, cfg, configuration, scheduler, candidate, event)
        end

        def run_candidate(project, cfg, configuration, scheduler, candidate, event)
          reserved = scheduler.reserve(candidate, now: event_time(event))
          options = {
            json: true, dry_run: configuration.settings.fetch("dry_run"),
            job_manifest: reserved.fetch(:manifest_path), project_entry: project,
            config_loader: ->(_path) { cfg }
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
          context.require_github_mutation!("issues")
          context.require_github_mutation!("pull_requests")
          context.require_external_command!("gh")
          context.require_network_host!("api.github.com")
        end

        def effective_config(project)
          Hive::Config.deep_merge(
            Hive::Config.load(project.fetch("path")),
            "daemon" => { "enabled" => true },
            "refactor_patrol" => { "enabled" => true }
          )
        end

        def event_time(event) = Time.iso8601(event.fetch("occurred_at"))
        def shadow?(configuration) = configuration.settings.fetch("shadow_mode")

        def shadow(configuration, event, rationale, candidate = nil)
          @shadow_sink.call(
            "module" => "architecture-patrol", "hook" => event.fetch("event_name"),
            "event_id" => event.fetch("event_id"), "rationale" => rationale,
            "job_id" => candidate && candidate[:job_id],
            "phase" => candidate && candidate.fetch(:action_phase, :discovery).to_s,
            "configuration_digest" => configuration.digest
          )
          0
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
