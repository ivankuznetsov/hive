require "json"
require "hive/attempts/store"
require "hive/config"
require "hive/daemon/retry_coordinator"
require "hive/task_resolver"

module Hive
  module Commands
    # Guarded operator actions for the one durable retry projection.
    class Retry
      ACTIONS = %w[manual repair reset abandon rearm re-arm].freeze

      def initialize(action, target, project: nil, generation: nil,
                     actor: nil, reason: nil, json: false,
                     attempt_store: nil, coordinator_factory: nil)
        @action = action.to_s
        @target = target
        @project = project
        @generation = generation
        @actor = actor
        @reason = reason
        @json = json
        @attempt_store = attempt_store || Hive::Attempts::Store.new
        @coordinator_factory = coordinator_factory
      end

      def call
        validate!
        task = Hive::TaskResolver.new(@target, project_filter: @project).resolve
        coordinator = coordinator_for(task)
        record = apply(coordinator)
        payload = {
          "schema" => "hive-retry-action",
          "schema_version" => 1,
          "ok" => true,
          "action" => canonical_action,
          "project" => task.project_name,
          "task" => task.slug,
          "retry" => record&.to_h
        }
        puts(@json ? JSON.generate(payload) : summary(payload))
        payload
      end

      private

      def validate!
        raise Hive::Error, "retry action must be one of #{ACTIONS.join(', ')}" unless ACTIONS.include?(@action)
        raise Hive::Error, "retry target is required" if @target.to_s.strip.empty?
        generation = Integer(@generation)
        raise ArgumentError if generation.negative?
        return if @action == "manual"

        raise Hive::Error, "--actor is required for #{@action}" if @actor.to_s.strip.empty?
        raise Hive::Error, "--reason is required for #{@action}" if @reason.to_s.strip.empty?
      rescue ArgumentError, TypeError
        raise Hive::Error, "--generation must be a non-negative integer"
      end

      def apply(coordinator)
        generation = Integer(@generation)
        case canonical_action
        when "manual" then coordinator.manual_retry(expected_generation: generation)
        when "repair" then coordinator.repair(expected_generation: generation, actor: @actor, reason: @reason)
        when "abandon" then coordinator.abandon(expected_generation: generation, actor: @actor, reason: @reason)
        when "rearm" then coordinator.rearm(expected_generation: generation, actor: @actor, reason: @reason)
        end
      end

      def canonical_action
        return "repair" if %w[repair reset].include?(@action)
        return "rearm" if %w[rearm re-arm].include?(@action)

        @action
      end

      def coordinator_for(task)
        return @coordinator_factory.call(task, @attempt_store) if @coordinator_factory

        config = Hive::Config.load(task.project_root)
        Hive::Daemon::RetryCoordinator.new(
          task_folder: task.folder, attempt_store: @attempt_store,
          schedule: Hive::Config.retry_backoff(config)
        )
      end

      def summary(payload)
        retry_record = payload.fetch("retry") || {}
        state = retry_record["state"] || "none"
        count = retry_record["retry_count"] || 0
        after = retry_record["retry_after"]
        suffix = after ? " until #{after}" : ""
        "#{payload.fetch('task')}: retry #{payload.fetch('action')} accepted; state=#{state} count=#{count}#{suffix}"
      end
    end
  end
end
