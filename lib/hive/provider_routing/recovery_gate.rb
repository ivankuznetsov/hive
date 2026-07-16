require "hive/config"
require "hive/task"
require "hive/provider_routing/router"

module Hive
  module ProviderRouting
    # Read-only-at-the-call-boundary recovery check used by daemon healers.
    # Selection temporarily claims the exact probe/cap resources that a real
    # spawn would need, then cancels them before returning; the final dispatch
    # repeats the authoritative claim immediately before process spawn.
    class RecoveryGate
      Result = Data.define(:dispatchable, :decision, :explanation)

      def initialize(router_factory: nil)
        @router_factory = router_factory || ->(now) { Router.new(clock: -> { now }) }
      end

      def call(row, now: Time.now.utc)
        task = Hive::Task.new(row.folder.to_s)
        cfg = Hive::Config.load(project_root_for(row.folder.to_s))
        router = @router_factory.call(now)
        configurations_for(task, cfg).each do |configuration|
          request = Request.new(
            configuration: configuration,
            checkpoint: "#{task.stage_index}-#{task.stage_name}",
            provenance: { "task" => task.slug, "stage" => task.stage_name, "recovery" => true },
            agent_config: cfg
          )
          decision = router.select(request)
          if decision.selected?
            router.cancel(decision, now: now)
            return Result.new(
              dispatchable: true,
              decision: decision,
              explanation: decision.explanation
            )
          end
        end

        Result.new(
          dispatchable: false,
          decision: nil,
          explanation: "no configured route is currently dispatchable"
        )
      rescue Hive::Error, SystemCallError => e
        Result.new(dispatchable: false, decision: nil, explanation: e.message)
      end

      private

      def configurations_for(task, cfg)
        return review_configurations(cfg) if task.stage_name == "review"

        profile = Hive::AgentProfiles.lookup(
          cfg.dig(task.stage_name, "agent") || "claude",
          cfg: cfg
        )
        [
          Configuration.from(
            cfg: cfg,
            stage_name: task.stage_name,
            agent: profile.name,
            source: "#{task.stage_name}.routing during daemon recovery"
          )
        ]
      end

      def review_configurations(cfg)
        review = cfg["review"].is_a?(Hash) ? cfg["review"] : {}
        entries = Array(review["reviewers"]) +
          %w[ci triage fix browser_test].filter_map { |role| review[role] }
        configurations = entries.filter_map.with_index do |entry, index|
          next unless entry.is_a?(Hash)

          Configuration.from(
            cfg: cfg,
            stage_name: "review",
            routing: entry["routing"],
            agent: entry["agent"] || "claude",
            model: entry["model"],
            effort: entry["effort"],
            source: "review recovery route #{index}"
          )
        end
        return configurations unless configurations.empty?

        [ Configuration.from(cfg: cfg, stage_name: "review", agent: "claude") ]
      end

      def project_root_for(folder)
        path = File.expand_path(folder)
        loop do
          return File.dirname(path) if File.basename(path) == ".hive-state"

          parent = File.dirname(path)
          raise Hive::ConfigError, "could not locate .hive-state above #{folder}" if parent == path

          path = parent
        end
      end
    end
  end
end
