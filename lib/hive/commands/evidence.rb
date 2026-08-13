require "json"
require "hive/artifacts/outcome_evidence/recovery"
require "hive/artifacts/outcome_evidence/store"
require "hive/config"
require "hive/lock"
require "hive/markers"
require "hive/task_resolver"
require "hive/terminal_outcome"

module Hive
  module Commands
    # Exact-CAS operator recovery for an exhausted or explicitly blocked
    # outcome-evidence package. The command never mutates the blocked ledger;
    # it advances a separate epoch and leaves ordinary workflow.retry admission
    # to the existing status/action boundary.
    class Evidence
      SUBCOMMANDS = %w[recover].freeze

      def initialize(subcommand, target, project: nil, stage: nil, json: false,
                     generation: nil, recovery_digest: nil, task_resolver: nil)
        @subcommand = subcommand.to_s
        @target = target.to_s
        @project_filter = project
        @stage_filter = stage
        @json = json
        @generation = generation.to_s
        @recovery_digest = recovery_digest.to_s
        @task_resolver = task_resolver
      end

      def call
        validate_arguments!
        task = resolve_task
        project = task.respond_to?(:project_name) ? task.project_name.to_s : @project_filter.to_s
        project = File.basename(task.project_root) if project.empty?
        payload = Hive::Lock.with_task_lock(
          task.folder, slug: task.slug, op: "outcome-evidence.recover"
        ) do
          recover(task, project)
        end
        if @json
          puts JSON.generate(payload)
        else
          puts "hive: outcome evidence recovery epoch advanced to #{payload.fetch('recovery_epoch')}"
          puts "  blocked generation preserved: #{payload.fetch('blocked_generation')}"
          puts "  next: refresh `hive status --operational --json` and invoke the task's guarded workflow.retry action"
        end
        payload
      end

      private

      def validate_arguments!
        unless SUBCOMMANDS.include?(@subcommand)
          raise Hive::UsageError, "unknown evidence subcommand #{@subcommand.inspect} (expected: recover)"
        end
        raise Hive::UsageError, "hive evidence recover requires TARGET" if @target.empty?
        unless @generation.match?(Hive::Artifacts::OutcomeEvidence::Proof::DIGEST)
          raise Hive::UsageError, "hive evidence recover requires --generation SHA256"
        end
        unless @recovery_digest.match?(Hive::Artifacts::OutcomeEvidence::Proof::DIGEST)
          raise Hive::UsageError, "hive evidence recover requires --recovery-digest SHA256"
        end
      end

      def resolve_task
        return @task_resolver.call if @task_resolver

        Hive::TaskResolver.new(
          @target, project_filter: @project_filter, stage_filter: @stage_filter
        ).resolve
      end

      def recover(task, project)
        marker = Hive::Markers.current(task.state_file)
        unless marker.name == :error &&
               Hive::TerminalOutcome.blocked_error?(marker.attrs) &&
               marker.attrs["generation"].to_s == @generation &&
               marker.attrs["recovery_digest"].to_s == @recovery_digest
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "task is not at the exact observed outcome-evidence blocker"
        end
        store = Hive::Artifacts::OutcomeEvidence::Store.new(task: task, project: project)
        pointer = store.current
        unless pointer && pointer["status"] == "blocked"
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "current outcome-evidence pointer is not blocked"
        end
        requirement = store.requirement(generation: pointer.fetch("generation"))
        task_generation = requirement.fetch("task_generation")
        record = Hive::Artifacts::OutcomeEvidence::Recovery.new(
          task: task, project: project
        ).advance!(
          pointer: pointer, task_generation: task_generation,
          expected_generation: @generation, expected_digest: @recovery_digest
        )
        Hive::Markers.set(
          task.state_file, :error,
          reason: "outcome_evidence_recovery_ready",
          generation: @generation,
          recovery_digest: @recovery_digest,
          recovery_epoch: record.fetch("epoch")
        )
        {
          "status" => "recovery_ready",
          "task" => task.slug.to_s,
          "blocked_generation" => record.fetch("blocked_generation"),
          "recovery_epoch" => record.fetch("epoch")
        }
      end
    end
  end
end
