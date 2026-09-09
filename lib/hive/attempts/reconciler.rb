require "open3"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/process_identity"
require "hive/attempts/storage_status"
require "hive/markers"
require "hive/task"

module Hive
  module Attempts
    ReconciledAttempt = Data.define(:attempt, :classification, :owner_status, :evidence)
    ReconciliationSnapshot = Data.define(
      :capacity, :attempts, :lost_attempts, :newly_lost_attempts,
      :terminal_attempts, :admission_view
    ) do
      def initialize(capacity:, attempts:, lost_attempts:, newly_lost_attempts:,
                     terminal_attempts:, admission_view: nil)
        super
      end
    end

    # Restart-safe observer. It adopts by identity, never wait2, and preserves
    # stale-but-matching owners as capacity-reserving suspects.
    class Reconciler
      attr_reader :store

      def initialize(store:, process_identity: ProcessIdentity.new, logger: nil,
                     condition_observer: nil, finalization_maintenance: nil)
        @store = store
        @process_identity = process_identity
        @logger = logger
        @condition_observer = condition_observer
        @finalization_maintenance = finalization_maintenance
        @logged = {}
      end

      def fetch(attempt_id)
        @store.fetch(attempt_id)
      end

      def reconcile(now: Time.now.utc)
        records = @store.active_attempts
        statuses = []
        newly_lost = []
        all_lost = []
        terminals = []
        effective_records = []

        records.each do |record|
          reconciled = reconcile_record(record, now: now)
          prepared = @finalization_maintenance&.prepare(reconciled.attempt)
          observation = observe_condition(reconciled, now: now)
          if prepared && %i[delivered acknowledged not_applicable].include?(observation)
            @finalization_maintenance.acknowledge(reconciled.attempt, :journal)
            @finalization_maintenance.publish_after_journal(reconciled.attempt)
          end
          statuses << reconciled
          newly_lost << reconciled.attempt if reconciled.classification == :lost
          all_lost << reconciled.attempt if reconciled.attempt.state == "lost"
          terminals << reconciled.attempt if reconciled.classification == :terminal
          effective_records << reconciled.attempt
          log_reconciliation(reconciled)
        rescue CompareAndSwapFailed
          # Another wrapper/reconciler won the transition. Re-read on the next
          # point lookup; no duplicate loss/terminal outcome is emitted by
          # this loser, and no second historical scan is needed for capacity.
          current = @store.fetch_hot(record.attempt_id)
          effective_records << current if current
          next
        end
        hot_attempts = effective_records.freeze
        admission_view = AdmissionView.new(store: @store, records: hot_attempts)
        capacity = admission_view.capacity(now: now)

        ReconciliationSnapshot.new(
          capacity: capacity,
          attempts: statuses.freeze,
          lost_attempts: all_lost.freeze,
          newly_lost_attempts: newly_lost.freeze,
          terminal_attempts: terminals.freeze,
          admission_view: admission_view
        )
      end

      def acknowledge_finalization(record, consumer)
        @finalization_maintenance&.acknowledge(record, consumer)
      end

      def promote_finalization(record)
        @finalization_maintenance&.promote(record) || false
      end

      def sweep_finalization_maintenance(now: Time.now.utc)
        @finalization_maintenance&.sweep_if_due(now: now)
      end

      def operational_storage_status(snapshot)
        attempts = snapshot&.admission_view&.records
        unless @finalization_maintenance
          return StorageStatus.unknown.merge(
            "hot" => {
              "records" => attempts&.size,
              "invalid" => attempts ? 0 : nil
            }
          )
        end

        @finalization_maintenance.storage_snapshot(
          hot_count: attempts&.size,
          invalid_hot_count: attempts ? 0 : nil
        )
      end

      private

      def observe_condition(status, now:)
        return :pending unless @condition_observer
        if @condition_observer.respond_to?(:observe)
          @condition_observer.observe(status, now: now)
        else
          @condition_observer.call(status, now: now) ? :delivered : :pending
        end
      end

      def reconcile_record(record, now:)
        return reconciled(record, :terminal, :not_applicable, { receipt: "valid" }) if record.state == "terminal"
        return reconciled(record, :already_lost, :not_applicable, { loss: record["loss"] }) if record.state == "lost"

        if record.state == "launching" && !record.claimed?
          return expire(record, "launch_timeout", now: now) if expired?(record, now)

          return reconciled(record, :reserved, :not_claimed, { deadline: record.active_deadline_value })
        end

        owner_status = @process_identity.status(record.wrapper)
        if record.state == "launching"
          return expire(record, "first_heartbeat_timeout", now: now,
                        owner_status: owner_status) if expired?(record, now)
          classification = owner_status == :matching ? :adopted : :suspect
          return reconciled(record, classification, owner_status, { deadline: record.active_deadline_value })
        end

        if owner_status == :matching || owner_status == :unverifiable
          classification = expired?(record, now) ? :suspect : :adopted
          classification = :suspect if owner_status == :unverifiable
          return reconciled(
            record, classification, owner_status,
            { heartbeat_at: record["heartbeat_at"], deadline: record.active_deadline_value }
          )
        end

        evidence = completion_evidence(record)
        lost = @store.mark_lost(
          record,
          reason: owner_status == :mismatched ? "owner_identity_mismatch" : "owner_gone",
          now: now,
          diagnostics: evidence.merge("owner_status" => owner_status.to_s)
        )
        reconciled(lost, :lost, owner_status, evidence)
      end

      def expire(record, reason, now:, owner_status: :not_applicable)
        lost = @store.mark_lost(
          record, reason: reason, now: now,
          diagnostics: { "owner_status" => owner_status.to_s }
        )
        reconciled(lost, :lost, owner_status, { deadline: record.active_deadline_value })
      end

      def expired?(record, now)
        record.active_deadline && now > record.active_deadline
      end

      # Receipt state has already won before this method is reached. Marker
      # evidence is accepted only when both projections match this generation;
      # git is inventory only and can never turn a record into success.
      def completion_evidence(record)
        task = locate_task(record)
        return { "evidence_precedence" => "none" } unless task

        marker = Hive::Markers.current(task.state_file)
        attrs = marker.attrs.to_h
        generation_matches = attrs["task_input_epoch"].to_s == record.task_input_epoch.to_s ||
                             attrs["task_generation"] == record.task_generation
        ownership_matches = attrs["ownership_generation"].nil? ||
                            attrs["ownership_generation"] == record.ownership_generation
        marker_matches = attrs["attempt_id"] == record.attempt_id &&
                         generation_matches && ownership_matches
        marker_evidence = if marker_matches
          {
            "name" => marker.name.to_s,
            "terminal" => Hive::Markers::TERMINAL_MARKER_NAMES.include?(marker.name),
            "state_file" => task.state_file
          }
        end
        {
          "evidence_precedence" => marker_evidence ? "current_generation_marker" : "git_inventory",
          "marker_evidence" => marker_evidence,
          "git_inventory" => git_inventory(task)
        }.compact
      end

      def locate_task(record)
        project = Hive::Config.find_project(record["project"])
        return nil unless project

        candidates = Dir.glob(File.join(project.fetch("hive_state_path"), "stages", "*", record["task_slug"]))
        candidates.filter_map do |folder|
          task = Hive::Task.new(folder)
          next if record["task_id"] && task.id.to_s != record["task_id"].to_s

          task
        rescue Hive::Error, SystemCallError
          nil
        end.first
      end

      def git_inventory(task)
        worktree = task.worktree_path
        return nil unless worktree && File.directory?(worktree)

        env = { "GIT_OPTIONAL_LOCKS" => "0" }
        revision, = Open3.capture2(env, "git", "-C", worktree, "rev-parse", "HEAD")
        status, = Open3.capture2(env, "git", "-C", worktree, "status", "--porcelain=v2", "-z")
        {
          "revision" => revision.strip,
          "dirty" => !status.empty?,
          "status_bytes" => status.bytesize,
          "success_inferred" => false
        }
      rescue SystemCallError
        { "unreadable" => true, "success_inferred" => false }
      end

      def reconciled(attempt, classification, owner_status, evidence = {})
        ReconciledAttempt.new(
          attempt: attempt, classification: classification,
          owner_status: owner_status, evidence: evidence
        )
      end

      def log_reconciliation(status)
        return unless @logger

        events =
          case status.classification
          when :terminal then [ :attempt_terminal ]
          when :lost then [ :attempt_lost ]
          when :suspect then [ :attempt_suspect ]
          when :reserved then [ :attempt_accepted ]
          when :adopted
            status.attempt.state == "launching" ? [ :attempt_claimed ] :
              [ :attempt_running, :attempt_adopted ]
          else []
          end
        events.each do |event|
          key = [ status.attempt.attempt_id, event, status.attempt.lease_version ]
          next if @logged[key]

          @logger.event(
            event,
            attempt_id: status.attempt.attempt_id,
            task_generation: status.attempt.task_generation,
            project: status.attempt["project"],
            slug: status.attempt["task_slug"],
            state: status.attempt.state,
            owner_status: status.owner_status.to_s
          )
          @logged[key] = true
        end
      end
    end
  end
end
