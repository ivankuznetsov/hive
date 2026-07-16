require "hive/attempt_lease_store"
require "hive/config"
require "hive/provider_routing/request"
require "hive/provider_routing/router"
require "hive/resumable_workflow"
require "hive/resumable_workflows/registry"
require "hive/workflow_selection"

module Hive
  module Daemon
    # Turns workflow-owned durable checkpoints into at most one outer resume
    # dispatch per checkpoint generation. File-format knowledge remains in the
    # registered adapter; this coordinator only understands normalized children.
    class WorkflowRecovery
      def initialize(router: Hive::ProviderRouting::Router.new,
                     lease_store: nil,
                     project_resolver: ->(name) { Hive::Config.find_project(name) },
                     config_loader: ->(root) { Hive::Config.load(root) },
                     workflow_resolver: nil,
                     registry: Hive::ResumableWorkflows::Registry,
                     logger: nil)
        @router = router
        @lease_store = lease_store || router.lease_store
        @project_resolver = project_resolver
        @config_loader = config_loader
        @workflow_resolver = workflow_resolver || lambda do |name, root|
          Hive::WorkflowSelection.fetch!(name, project_root: root)
        end
        @registry = registry
        @logger = logger
        @observed_checkpoints = {}
      end

      # Returns dispatch-ready outer resumes. A selected provider decision is
      # an eligibility reservation only: the actual nested agent spawn routes
      # again at its final dispatch boundary.
      def candidates(rows, now: Time.now.utc)
        Array(rows).filter_map { |row| candidate_for(row, now: now) }
      end

      def candidate_for(row, now: Time.now.utc)
        return if row.live_task_lock == true
        return if %w[agent_running complete archived].include?(row.action.to_s)

        project = @project_resolver.call(row.project)
        return unless project

        root = project.fetch("path")
        workflow = @workflow_resolver.call(row.workflow, root)
        adapter = @registry.resolve(workflow)
        return unless adapter

        config = @config_loader.call(root)
        snapshot = adapter.snapshot(row: row, project_root: root, config: config)
        observe_checkpoint!(snapshot)
        decision = select_child(snapshot, adapter, row, config)
        return unless decision

        claim = @lease_store.claim_recovery(
          workflow_id: snapshot.workflow_id,
          checkpoint_generation: snapshot.checkpoint_generation,
          provenance: {
            "project" => row.project,
            "slug" => row.slug,
            "workflow" => row.workflow,
            "checkpoint_fingerprint" => snapshot.checkpoint_fingerprint
          },
          now: now
        )
        # AttemptLeaseStore treats a same-owner re-claim as idempotently
        # successful. For recovery that lease already belongs to the earlier
        # coordinator result, so only a freshly-created claim may dispatch.
        unless claim.claimed && claim.reason == "claimed"
          @router.cancel(decision, now: now)
          log(:workflow_recovery_skipped, row, reason: claim.reason,
              checkpoint_generation: snapshot.checkpoint_generation)
          return
        end

        command = adapter.resume_command(row: row, snapshot: snapshot)
        Hive::ResumableWorkflow::Resume.new(
          row: row,
          snapshot: snapshot,
          command: command,
          recovery_lease: claim.lease,
          provider_decisions: [ decision ].freeze
        )
      rescue Hive::ConfigError, Hive::ResumableWorkflow::SnapshotError,
             Hive::ProviderRouting::StoreError, Hive::AttemptLeaseStoreError,
             KeyError, SystemCallError, IOError => e
        log(:workflow_recovery_error, row, error_class: e.class.name, message: e.message)
        nil
      end

      # A successful outer spawn consumes the generation forever; a blocked or
      # failed spawn releases it so a later tick can retry. Provider eligibility
      # reservations are always released because the resumed stage claims its
      # own authoritative attempt lease immediately before its real spawn.
      def finish(resume, dispatched:, now: Time.now.utc)
        Array(resume.provider_decisions).each { |decision| @router.cancel(decision, now: now) }
        if dispatched
          @lease_store.complete(resume.recovery_lease, now: now)
        else
          @lease_store.release(resume.recovery_lease, now: now)
        end
      end

      private

      def select_child(snapshot, adapter, row, config)
        snapshot.retryable_children.each do |child|
          routing = adapter.configuration_for(child: child, row: row, config: config)
          request = Hive::ProviderRouting::Request.new(
            configuration: routing,
            checkpoint: "#{snapshot.checkpoint_generation}:#{child.child_id}",
            provenance: {
              "project" => row.project,
              "slug" => row.slug,
              "workflow_id" => snapshot.workflow_id,
              "child_id" => child.child_id,
              "failed_provider" => child.failed_provider
            }
          )
          decision = @router.select(request)
          return decision if decision.selected?

          log(:workflow_recovery_child_waiting, row,
              child_id: child.child_id, reason: decision.wait_reason)
        end
        nil
      end

      def observe_checkpoint!(snapshot)
        prior = @observed_checkpoints[snapshot.workflow_id]
        if prior && snapshot.checkpoint_generation < prior.fetch(:generation)
          raise Hive::ResumableWorkflow::SnapshotError,
                "workflow #{snapshot.workflow_id.inspect} checkpoint generation regressed " \
                "from #{prior.fetch(:generation)} to #{snapshot.checkpoint_generation}"
        end
        if prior && snapshot.checkpoint_generation == prior.fetch(:generation) &&
            snapshot.checkpoint_fingerprint != prior.fetch(:fingerprint)
          raise Hive::ResumableWorkflow::SnapshotError,
                "workflow #{snapshot.workflow_id.inspect} changed fingerprint without advancing generation"
        end

        @observed_checkpoints[snapshot.workflow_id] = {
          generation: snapshot.checkpoint_generation,
          fingerprint: snapshot.checkpoint_fingerprint
        }
      end

      def log(event, row, **payload)
        @logger&.event(event, project: row.project, slug: row.slug,
                             workflow: row.workflow, **payload)
      end
    end
  end
end
