require "json"
require "stringio"
require "hive/atomic_file"
require "hive/commands/refactor_patrol"
require "hive/refactor_patrol/scheduled_slice_producer"

module Hive
  module Commands
    # One supervised current-main slice. Durable completion precedes the receipt.
    class RefactorPatrolScheduled
      def initialize(project, result_file:, config_loader: ->(path) { Hive::Config.load(path) },
                     producer_factory: nil, command_factory: nil, budget_factory: nil)
        @project = project
        @result_file = result_file
        @config_loader = config_loader
        @producer_factory = producer_factory || ->(entry, cfg) {
          Hive::RefactorPatrol::ScheduledSliceProducer.new(entry: entry, cfg: cfg)
        }
        @command_factory = command_factory || ->(project, **options) { RefactorPatrol.new(project, **options) }
        @budget_factory = budget_factory || ->(entry, cfg) {
          Hive::Patrol::LaunchBudget.new(
            entry.fetch("path"), cfg: cfg, project_id: entry.fetch("project_id"),
            project_name: entry.fetch("name"), engine: :architecture
          )
        }
      end

      def call
        entry = Hive::Config.find_project(@project)
        raise Hive::ConfigError, "unknown project #{@project.inspect}" unless entry
        path = validate_result_path!(entry)
        cfg = @config_loader.call(entry.fetch("path"))
        unless cfg.dig("daemon", "enabled") == true && cfg.dig("refactor_patrol", "enabled") == true &&
               Hive::Workflows.coding_id?(cfg["default_workflow"])
          raise Hive::ConfigError, "scheduled Architecture Patrol is disabled"
        end
        budget = @budget_factory.call(entry, cfg)
        return emit(path, ok: true, reason: "discovery_allowance_exhausted") unless
          budget.remaining_launches.positive?

        producer = @producer_factory.call(entry, cfg)
        claim = producer.claim
        return emit(path, ok: true, reason: "no_available_slice") unless claim

        report = @command_factory.call(
          entry.fetch("name"), json: true, output: StringIO.new, project_entry: entry,
          config_loader: ->(_path) { cfg }, scheduled_slice: claim
        ).call
        complete = report.is_a?(Hash) && report["ok"] == true &&
                   report["review_complete"] == true && Array(report["review_errors"]).empty? &&
                   report["last_scanned_sha"] == claim.fetch("analysis_sha")
        if complete
          complete = producer.complete(claim_id: claim.fetch("id"), result: report)
          claim = nil if complete
        end
        emit(path, ok: !!complete, reason: complete ? "completed" : "incomplete", report: report)
      ensure
        producer.release(claim_id: claim.fetch("id")) if producer && claim
      end

      private

      def validate_result_path!(entry)
        root = File.expand_path(File.join(entry.fetch("hive_state_path"), "refactor_patrol", "v2", "results"))
        path = File.expand_path(@result_file)
        unless File.dirname(path) == root && File.basename(path).match?(/\Ascheduled-[0-9a-f]{32}\.json\z/)
          raise Hive::ConfigError, "scheduled Architecture Patrol result path is outside its fenced root"
        end
        path
      end

      def emit(path, ok:, reason:, report: nil)
        payload = { "schema" => "hive-refactor-patrol-scheduled-run", "schema_version" => 1,
                    "ok" => ok, "reason" => reason, "report" => report || {} }
        FileUtils.mkdir_p(File.dirname(path))
        Hive::AtomicFile.write(path, "#{JSON.generate(payload)}\n", mode: 0o600)
        puts JSON.generate(payload)
        payload
      end
    end
  end
end
