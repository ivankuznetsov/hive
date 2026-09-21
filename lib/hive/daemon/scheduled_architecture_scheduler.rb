require "shellwords"
require "securerandom"
require "hive/config"
require "hive/workflows"
require "hive/patrol/launch_budget"
require "hive/refactor_patrol/state_store"

module Hive
  module Daemon
    # The child owns the durable slice claim; the daemon owns dispatch cadence.
    class ScheduledArchitectureScheduler
      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) }, dry_run: false)
        @dry_run = dry_run
        @registry = registry
        @config_loader = config_loader
        @events = []
        @pending = {}
        @next_check = {}
      end

      def candidates(now: Time.now)
        @events.clear
        @registry.call.filter_map do |entry|
          project = entry.fetch("name")
          next if @pending[project] || (@next_check[project] && now < @next_check[project])

          cfg = @config_loader.call(entry.fetch("path"))
          next unless enabled?(cfg)
          interval = cfg.dig("patrol", "poll_interval_sec") || 600
          @next_check[project] = now + interval
          last_run = Hive::RefactorPatrol::StateStore.new(
            entry.fetch("path"), hive_state_path: entry.fetch("hive_state_path")
          ).state["last_run_at"]
          next if last_run && now < Time.iso8601(last_run) + interval
          next unless budget(entry, cfg, now).remaining_launches.positive?

          @next_check.delete(project)
          {
            project: project, entry: entry, patrol_kind: :architecture,
            action_phase: :scheduled, job_id: "scheduled", merged_at: nil,
            slug: "refactor-patrol-scheduled", stage: "refactor-patrol"
          }
        rescue StandardError => error
          @events << { status: :blocked, project: project, lane: "scheduled",
                       reason: "scheduled_discovery_unavailable", error: error.message[0, 2_000] }
          nil
        end
      end

      def drain_events
        events = @events
        @events = []
        events
      end

      def reserve(candidate, now: Time.now)
        entry = candidate.fetch(:entry)
        project = entry.fetch("name")
        cfg = @config_loader.call(entry.fetch("path"))
        return if @pending[project] || !enabled?(cfg)
        return unless budget(entry, cfg, now).remaining_launches.positive?

        run_id = SecureRandom.hex(16)
        path = File.join(entry.fetch("hive_state_path"), "refactor_patrol", "v2", "results",
                         "scheduled-#{run_id}.json")
        @pending[project] = true unless @dry_run
        @next_check[project] = now + (cfg.dig("patrol", "poll_interval_sec") || 600)
        candidate.merge(
          command: "hive refactor-patrol-scheduled #{Shellwords.escape(project)} " \
                   "--result-file #{Shellwords.escape(path)} --json",
          state_file_path: nil, state_file_mtime: nil,
          dispatch_token: { kind: :architecture_patrol, phase: :scheduled,
                            registration: project, job_id: "scheduled-#{run_id}", result_path: path,
                            poll_interval_sec: cfg.dig("patrol", "poll_interval_sec") || 600 }
        )
      end

      def cancel(dispatch, reason:, now: Time.now)
        @pending.delete(dispatch.fetch(:project))
      end

      def complete(dispatch_token:, exit_code:, envelope:, now: Time.now)
        project = dispatch_token.fetch(:registration)
        @pending.delete(project)
        success = exit_code == 0 && envelope.is_a?(Hash) && envelope["ok"] == true
        @next_check[project] = now + dispatch_token.fetch(:poll_interval_sec, 600)
        report = envelope.is_a?(Hash) ? envelope.fetch("report", {}) : {}
        reason = envelope.is_a?(Hash) ? envelope["reason"] : nil
        status = if !success
          :retry
        elsif %w[no_available_slice discovery_allowance_exhausted].include?(reason)
          :skipped
        else
          :closed
        end
        { status: status, reason: reason, job_id: dispatch_token[:job_id],
          lane: "scheduled", fix_count: Array(report["fix"]).size,
          discuss_count: Array(report["discuss"]).size, dismiss_count: Array(report["dismiss"]).size }
      end

      private

      def enabled?(cfg)
        cfg.dig("daemon", "enabled") == true &&
          Hive::Workflows.coding_id?(cfg["default_workflow"]) &&
          cfg.dig("refactor_patrol", "enabled") == true
      end

      def budget(entry, cfg, now)
        Hive::Patrol::LaunchBudget.new(
          entry.fetch("path"), cfg: cfg, project_id: entry.fetch("project_id"),
          project_name: entry.fetch("name"), engine: :architecture, clock: -> { now }
        )
      end
    end
  end
end
