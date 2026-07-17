require "digest"
require "etc"
require "json"
require "hive/babysitter/job_store"
require "hive/finalization/outcome_validator"
require "hive/task_journal"
require "hive/task_projection/store"
require "hive/task_resolver"

module Hive
  module Commands
    # Guarded local operator command for exceptional no-PR approval and its
    # append-only reversal. There is intentionally no --yes switch or
    # non-interactive path.
    class FinalizeOutcome
      ACTIONS = %w[approve rearm].freeze
      Result = Data.define(:status, :event_id, :state)

      def initialize(target, action, outcome: nil, reason: nil, evidence: nil, project: nil,
                     input: $stdin, output: $stdout, clock: -> { Time.now.utc },
                     validator: nil, snapshot_loader: nil, actor_resolver: nil)
        @target = target
        @action = action.to_s
        @outcome = outcome
        @reason = reason.to_s.strip
        @evidence = evidence
        @project_filter = project
        @input = input
        @output = output
        @clock = clock
        @snapshot_loader = snapshot_loader || ->(url, cfg) { Hive::Gh.exact_pr_snapshot(url, cfg: cfg) }
        @validator = validator || Hive::Finalization::OutcomeValidator.new(
          snapshot_loader: @snapshot_loader, clock: @clock
        )
        @actor_resolver = actor_resolver || method(:local_actor)
      end

      def call
        validate_arguments!
        require_interactive!
        task = Hive::TaskResolver.new(
          @target, project_filter: @project_filter, stage_filter: "8-finalize"
        ).resolve
        context = load_context(task)
        @action == "approve" ? approve(task, context) : rearm(task, context)
      end

      private

      def validate_arguments!
        unless ACTIONS.include?(@action)
          raise Hive::InvalidTaskPath, "ACTION must be approve or rearm"
        end
        raise Hive::InvalidTaskPath, "--reason is required" if @reason.empty?
        if @action == "approve" && @outcome.to_s.strip.empty?
          raise Hive::InvalidTaskPath, "approve requires --outcome"
        end
        if @action == "rearm" && (!@outcome.to_s.strip.empty? || !@evidence.to_s.strip.empty?)
          raise Hive::InvalidTaskPath, "rearm does not accept --outcome or --evidence"
        end
      end

      def require_interactive!
        interactive = @input.respond_to?(:tty?) && @input.tty?
        return if interactive

        raise Hive::InvalidTaskPath, "finalize-outcome approval is local-TTY only"
      rescue IOError
        raise Hive::InvalidTaskPath, "finalize-outcome approval is local-TTY only"
      end

      def load_context(task)
        records = Hive::TaskProjection.read_journal(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
        finalization = Hive::Finalization::Projection.project(records: records)
        if finalization.fetch("state") == "unfinalized"
          raise Hive::Finalization::OutcomeValidator::NotEligible,
                "task has no authoritative finalize handoff; rerun finalize first"
        end
        store = Hive::Babysitter::JobStore.new(project_root: task.project_root, clock: @clock)
        job = store.read(finalization.fetch("job_id"))
        current = store.current_job(
          task_slug: task.slug, task_generation: finalization.fetch("task_generation")
        )
        unless current&.fetch("job_id") == job.fetch("job_id")
          raise Hive::Finalization::OutcomeValidator::NotEligible,
                "finalization job is not current for this task generation"
        end
        cfg = Hive::Config.load(task.project_root)
        snapshot = @snapshot_loader.call(finalization.fetch("pr_url"), cfg)
        {
          records: records, finalization: finalization, store: store,
          job: job, cfg: cfg, snapshot: snapshot
        }
      end

      def approve(task, context)
        normalized_outcome = @outcome.to_s.strip
        finalization = context.fetch(:finalization)
        if finalization.fetch("state") == "approved_no_pr"
          terminal = context.fetch(:records).find do |record|
            record["event_id"] == finalization.dig("evidence", "terminal_event_id")
          end
          if terminal&.dig("payload", "outcome") == normalized_outcome
            context.fetch(:store).retire_after_no_pr_approval!(
              finalization.fetch("job_id"), approval_event_id: terminal.fetch("event_id"), now: @clock.call
            )
            return existing_result(terminal, task, "approval")
          end
        end
        evidence = @validator.validate!(
          outcome: normalized_outcome,
          evidence: @evidence,
          finalization: context.fetch(:finalization),
          job: context.fetch(:job),
          current_snapshot: context.fetch(:snapshot),
          task: task,
          cfg: context.fetch(:cfg)
        )
        predecessor = context.fetch(:records).reverse_each.find do |record|
          Hive::Finalization::Event.finalization?(record)
        end&.fetch("event_id", nil)
        evidence_digest = ::Digest::SHA256.hexdigest(
          canonical_json("predecessor_event_id" => predecessor, "evidence" => evidence)
        )[0, 20]
        event_id = "#{finalization.fetch('job_id')}:no-pr:#{normalized_outcome}:#{evidence_digest}"
        existing = context.fetch(:records).find { |record| record["event_id"] == event_id }
        return existing_result(existing, task, "approval") if existing

        confirmation = "approve #{task.slug} #{finalization.fetch('task_generation')} #{normalized_outcome}"
        present_confirmation(
          task: task, finalization: finalization, snapshot: context.fetch(:snapshot),
          action: "approve #{normalized_outcome}", evidence: evidence, confirmation: confirmation
        )
        require_exact_confirmation!(confirmation)
        actor = @actor_resolver.call
        occurred_at = @clock.call.utc.iso8601(6)
        append_operator_event(
          task: task, context: context, event_id: event_id, event_type: "no_pr_approved",
          occurred_at: occurred_at, actor: actor, reason: @reason,
          evidence: evidence, payload_extra: {
            "outcome" => normalized_outcome,
            "operator_reason" => @reason,
            "operator_actor" => actor
          }
        )
        context.fetch(:store).retire_after_no_pr_approval!(
          finalization.fetch("job_id"), approval_event_id: event_id, now: @clock.call
        )
        projection = Hive::TaskProjection::Store.new(task_folder: task.folder).rebuild!
        @output.puts "Approved #{normalized_outcome} for #{task.slug}; archive awaits reconciliation."
        Result.new(status: :approved, event_id: event_id,
                   state: projection.to_h.dig("finalization", "state"))
      end

      def rearm(task, context)
        finalization = context.fetch(:finalization)
        if finalization.fetch("state") == "babysitter_active"
          existing = context.fetch(:records).reverse_each.find do |record|
            record["event_type"] == "finalization_rearmed" &&
              record.dig("payload", "job_id") == finalization.fetch("job_id")
          end
          if existing
            context.fetch(:store).rearm_after_approval!(
              finalization.fetch("job_id"), rearm_event_id: existing.fetch("event_id"), now: @clock.call
            )
            return existing_result(existing, task, "re-arm")
          end
        end
        unless finalization.fetch("state") == "approved_no_pr"
          raise Hive::Finalization::OutcomeValidator::NotEligible,
                "rearm requires an unconsumed approved no-PR outcome"
        end
        unless %w[terminal active].include?(context.fetch(:job).fetch("state"))
          raise Hive::Finalization::OutcomeValidator::NotEligible,
                "rearm requires the current retired or active journal-backed babysitter job"
        end

        terminal_id = finalization.dig("evidence", "terminal_event_id")
        event_id = "#{finalization.fetch('job_id')}:rearm:#{terminal_id}"
        existing = context.fetch(:records).find { |record| record["event_id"] == event_id }
        return existing_result(existing, task, "re-arm") if existing

        confirmation = "rearm #{task.slug} #{finalization.fetch('task_generation')}"
        present_confirmation(
          task: task, finalization: finalization, snapshot: context.fetch(:snapshot),
          action: "rearm watching", evidence: { "approval_event_id" => terminal_id },
          confirmation: confirmation
        )
        require_exact_confirmation!(confirmation)
        actor = @actor_resolver.call
        occurred_at = @clock.call.utc.iso8601(6)
        append_operator_event(
          task: task, context: context, event_id: event_id, event_type: "finalization_rearmed",
          occurred_at: occurred_at, actor: actor, reason: @reason,
          evidence: { "approval_event_id" => terminal_id }, payload_extra: {
            "active" => true,
            "approval_event_id" => terminal_id,
            "operator_reason" => @reason,
            "operator_actor" => actor
          }
        )
        context.fetch(:store).rearm_after_approval!(
          finalization.fetch("job_id"), rearm_event_id: event_id, now: @clock.call
        )
        projection = Hive::TaskProjection::Store.new(task_folder: task.folder).rebuild!
        @output.puts "Re-armed babysitter watching for #{task.slug}."
        Result.new(status: :rearmed, event_id: event_id,
                   state: projection.to_h.dig("finalization", "state"))
      end

      def append_operator_event(task:, context:, event_id:, event_type:, occurred_at:, actor:, reason:,
                                evidence:, payload_extra:)
        finalization = context.fetch(:finalization)
        source = context.fetch(:records).reverse_each.find { |record| record["task"].is_a?(Hash) }
        raise Hive::Finalization::OutcomeValidator::NotEligible, "journal task identity is missing" unless source

        Hive::TaskJournal::Writer.new(task_folder: task.folder, clock: @clock).append_once(
          event_id: event_id,
          event_type: event_type,
          occurred_at: occurred_at,
          observed_at: occurred_at,
          task: source.fetch("task"),
          workflow: source["workflow"] || task.workflow.id.to_s,
          stage: "8-finalize",
          attempt_id: finalization.fetch("finalize_attempt_id"),
          task_generation: finalization.fetch("task_generation"),
          ownership_generation: "operator:#{actor.fetch('uid')}:#{occurred_at}",
          reason: reason,
          producer: actor.merge("kind" => "operator", "channel" => "local_tty"),
          evidence: [ { "kind" => "operator_validation", "value" => evidence } ],
          provenance: { "source" => "hive-finalize-outcome", "channel" => "local_tty" },
          payload: coordinates(finalization).merge(payload_extra)
        )
      end

      def present_confirmation(task:, finalization:, snapshot:, action:, evidence:, confirmation:)
        @output.puts "Exceptional finalize outcome"
        @output.puts "  task: #{task.slug} (generation #{finalization.fetch('task_generation')})"
        @output.puts "  job: #{finalization.fetch('job_id')}"
        @output.puts "  PR: #{snapshot.url} [#{snapshot.state}]"
        @output.puts "  action: #{action}"
        @output.puts "  reason: #{@reason}"
        @output.puts "  evidence: #{canonical_json(evidence)}"
        @output.puts "  consequence: archive reconciliation may remove the local task worktree and branch"
        @output.puts "Type exactly: #{confirmation}"
        @output.print "> "
        @output.flush if @output.respond_to?(:flush)
      end

      def require_exact_confirmation!(expected)
        actual = @input.gets
        unless actual&.chomp == expected
          raise Hive::InvalidTaskPath, "finalize-outcome confirmation cancelled or did not match exactly"
        end
      end

      def existing_result(record, task, label)
        projection = Hive::TaskProjection::Store.new(task_folder: task.folder).rebuild!
        state = projection.to_h.dig("finalization", "state")
        @output.puts "Existing #{label} event #{record.fetch('event_id')} is already recorded."
        Result.new(status: :already_recorded, event_id: record.fetch("event_id"), state: state)
      end

      def local_actor
        uid = Process.euid
        login = Etc.getlogin.to_s.strip
        login = Etc.getpwuid(uid).name.to_s.strip if login.empty?
        raise Hive::Finalization::OutcomeValidator::NotEligible, "could not resolve local operator identity" if login.empty?

        { "uid" => uid, "login" => login }
      rescue ArgumentError
        raise Hive::Finalization::OutcomeValidator::NotEligible, "could not resolve local operator identity"
      end

      def coordinates(finalization)
        Hive::Finalization::Event::COORDINATES.to_h do |key|
          [ key, finalization.fetch(key) ]
        end
      end

      def canonical_json(value)
        JSON.generate(value, sort_keys: true)
      end
    end
  end
end
