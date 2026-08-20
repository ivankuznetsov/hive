require "json"
require "json_schemer"
require "digest"
require "pathname"
require "securerandom"
require "shellwords"
require "time"
require "uri"
require "hive/config"
require "hive/gh"
require "hive/lock"
require "hive/process_kill"
require "hive/refactor_patrol/checkout_guard"
require "hive/refactor_patrol/architecture_intake_transitions"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/architecture_occurrence_lifecycle"
require "hive/refactor_patrol/claim_liveness_resolver"
require "hive/refactor_patrol/discovery_capacity"
require "hive/refactor_patrol/action_claim_transitions"
require "hive/refactor_patrol/claim_maintenance_transitions"
require "hive/refactor_patrol/discovery_transitions"
require "hive/refactor_patrol/pr_manifest"
require "hive/refactor_patrol/pr_manifest_resolver"
require "hive/refactor_patrol/merge_classifier"
require "hive/refactor_patrol/merge_classifier_runner"
require "hive/refactor_patrol/post_merge_batch_store"
require "hive/refactor_patrol/post_merge_slice_mapper"
require "hive/refactor_patrol/policy"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/process_group_resolver"
require "hive/refactor_patrol/repository_ownership"
require "hive/modules/event_publisher"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/patrol/launch_budget"
require "hive/workflow_package/canonical_json"
require "hive/workflows"

module Hive
  module Daemon
    # Exposes durable merged-PR architecture work to PatrolArbiter and owns
    # the discovery claim/fence lifecycle around its child process.
    class RefactorPatrolScheduler
      PATROL_STAGE = "refactor-patrol".freeze
      PATROL_SLUG_PREFIX = "refactor-patrol".freeze
      MODULE_SCHEDULE = "*/10 * * * *".freeze
      RETRY_BACKOFF_SEC = 60
      RUNAWAY_RETRY_BACKOFF_SEC =
        Hive::RefactorPatrol::ActionClaimTransitions::RETRY_BACKOFF_SEC
      DEFERRED_RESOURCE_EXHAUSTION_REASONS = %w[
        token_limit turn_limit agent_in_flight daily_agent_spawn_limit
      ].freeze
      ACTION_EFFECT_CAPACITY_RESERVE = 1
      SUPPORTED_REPORT_SCHEMA_VERSIONS = [
        Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol")
      ].freeze

      class ReservationBlocked < StandardError
        attr_reader :reason, :evidence

        def initialize(reason, evidence = {})
          @reason = reason.to_s
          @evidence = evidence
          super(@reason)
        end
      end

      ProcessGroupResolver = Hive::RefactorPatrol::ProcessGroupResolver

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     job_store_factory: nil,
                     checkout_guard_factory: nil, repository_resolver: nil,
                     repository_ownership: nil,
                     owner: nil, claim_resolver: ProcessGroupResolver.new,
                     claim_liveness_resolver: Hive::RefactorPatrol::ClaimLivenessResolver.new,
                     lease_sec: 7200, dry_run: false,
                     migration_authority: :legacy, migration_ownership: nil,
                     migration_snapshot: nil, evidence_store_factory: nil,
                     event_publisher: nil, module_execution: nil,
                     classifier_factory: nil, manifest_resolver_factory: nil,
                     post_merge_batch_store_factory: nil,
                     post_merge_slice_mapper: nil)
        @registry = registry
        @config_loader = config_loader
        @job_store_factory = job_store_factory
        @checkout_guard_factory = checkout_guard_factory || lambda do |path, branch|
          Hive::RefactorPatrol::CheckoutGuard.new(path, default_branch: branch)
        end
        @repository_resolver = repository_resolver || lambda do |entry, cfg|
          Hive::Gh.repository_identity(entry.fetch("path"), cfg: cfg)
        end
        @repository_ownership = repository_ownership || Hive::RefactorPatrol::RepositoryOwnership.new(
          registry: registry, config_loader: config_loader,
          identity_resolver: @repository_resolver
        )
        @owner_pid = Process.pid
        @owner_process_start_time = Hive::Lock.process_start_time(Process.pid)
        @owner = owner || "daemon-#{Process.pid}-#{@owner_process_start_time || 'unverified'}"
        @claim_resolver = claim_resolver
        @claim_liveness_resolver = claim_liveness_resolver
        @lease_sec = lease_sec.to_i
        @dry_run = dry_run
        @migration_authority = migration_authority
        @migration_ownership = migration_ownership || lambda do |entry, module_name, authority|
          Hive::Modules::Migration::Patrols.admission_allowed?(
            entry.fetch("path"), module_name, authority: authority,
            hive_state_path: entry["hive_state_path"]
          )
        end
        @migration_snapshot = migration_snapshot || lambda do |entry, module_name|
          Hive::Modules::Migration::Patrols.ownership_snapshot(
            entry.fetch("path"), module_name,
            hive_state_path: entry["hive_state_path"]
          )
        end
        @evidence_store_factory = evidence_store_factory || lambda do |entry|
          Hive::Modules::Migration::EvidenceStore.new(
            root: File.join(
              entry.fetch("hive_state_path"), "module-runtime", "migration",
              "patrol-evidence"
            )
          )
        end
        @event_publisher = event_publisher || Hive::Modules::EventPublisher.new
        @module_execution = module_execution
        @classifier_factory = classifier_factory
        @manifest_resolver_factory = manifest_resolver_factory
        @post_merge_batch_store_factory = post_merge_batch_store_factory
        @post_merge_slice_mapper = post_merge_slice_mapper ||
                                   Hive::RefactorPatrol::PostMergeSliceMapper.new
        @architecture_intake_transitions =
          Hive::RefactorPatrol::ArchitectureIntakeTransitions.new(
            config_loader: @config_loader,
            migration_snapshot: ->(entry) { @migration_snapshot.call(entry, "architecture-patrol") },
            evidence_store_factory: @evidence_store_factory,
            module_execution: @module_execution,
            admission_error: ReservationBlocked
          )
        @occurrence_lifecycle =
          Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle.new(
            migration_authority: @migration_authority,
            dry_run: @dry_run,
            evidence_store_factory: @evidence_store_factory,
            event_publisher: @event_publisher,
            module_schedule: MODULE_SCHEDULE,
            reservation_error: ReservationBlocked
          )
        @discovery_transitions =
          Hive::RefactorPatrol::DiscoveryTransitions.new(
            config_loader: @config_loader,
            migration_snapshot: @migration_snapshot,
            evidence_store_factory: @evidence_store_factory,
            module_execution: @module_execution,
            owner: @owner,
            owner_pid: @owner_pid,
            owner_process_start_time: @owner_process_start_time,
            lease_sec: @lease_sec,
            claim_resolver: @claim_resolver,
            claim_liveness_resolver: @claim_liveness_resolver,
            reservation_error: ReservationBlocked,
            occurrence_lifecycle: @occurrence_lifecycle
          )
        @claim_maintenance_transitions =
          Hive::RefactorPatrol::ClaimMaintenanceTransitions.new
        @events = []
        @schemers = SUPPORTED_REPORT_SCHEMA_VERSIONS.to_h do |version|
          [ version, JSONSchemer.schema(Pathname.new(Hive::Schemas.schema_path("hive-refactor-patrol", version: version))) ]
        end
      end

      def candidates(now: Time.now)
        @events.clear
        managed = managed_entries
        stores_by_project = {}
        block_configuration_errors(now)
        due_by_project = managed.to_h do |entry|
          store = begin
            store_for(entry)
          rescue StandardError => error
            recovery_state_unavailable(entry, error)
            nil
          end
          next [ entry.fetch("name"), [] ] unless store
          stores_by_project[entry.fetch("name")] = store

          unless recover_occurrences(store, entry, now)
            next [ entry.fetch("name"), [] ]
          end
          recover_post_merge_batches(entry, store, now)
          classifications = classification_work(entry, store, now)
          claimable = if discovery_available?(entry)
            store.claimable_jobs(
              now: now,
              claim_liveness_resolver: @claim_liveness_resolver
            )
          else
            []
          end
          # JobStore discovery is merged-PR/post-merge work. Its claim and
          # provider backoff remain authoritative, but it never consults the
          # independent scheduled-architecture daily allowance.
          discovery = claimable
          work = classifications +
                 discovery.map { |job| { aggregate: job, phase: :discovery } } +
                 store.actionable_jobs(now: now).map { |job| { aggregate: job, phase: :action } }
          [ entry.fetch("name"), work ]
        end
        return [] if due_by_project.values.all?(&:empty?)

        ownership_snapshot = if @repository_ownership.respond_to?(:snapshot)
          @repository_ownership.snapshot
        else
          @repository_ownership
        end

        managed.flat_map do |entry|
          project = entry.fetch("name")
          work = due_by_project.fetch(project)
          next [] if work.empty?

          store = stores_by_project.fetch(project)
          work.filter_map do |item|
            if %i[classification post_merge].include?(item.fetch(:phase))
              next candidate_for_classification(
                entry, item.fetch(:classification), phase: item.fetch(:phase)
              )
            end
            aggregate = item.fetch(:aggregate)
            if (capacity = effect_capacity_exhaustion(
              store, aggregate, phase: item.fetch(:phase), now: now
            ))
              aggregate = rollover_effect_capacity(
                entry, store, aggregate, capacity, now
              )
              next unless aggregate
            end
            ownership = repository_ownership_decision(
              entry, aggregate, phase: item.fetch(:phase),
              ownership_resolver: ownership_snapshot
            )
            if ownership.blocked?
              block(
                entry, aggregate, reason: ownership.reason,
                evidence: ownership.evidence, now: now, phase: item.fetch(:phase)
              )
              next
            end

            candidate_for(entry, aggregate, phase: item.fetch(:phase))
          end
        end.sort_by { |candidate| [ parse_time(candidate[:merged_at]), candidate[:job_id] ] }
      rescue Hive::ConfigError, Hive::RefactorPatrol::JobStore::Error => e
        @events << { status: :blocked, reason: "scheduler_error", error: "#{e.class}: #{e.message}" }
        []
      end

      def drain_events
        drained = @events.dup
        @events.clear
        drained
      end

      def reserve(candidate, now: Time.now)
        entry = candidate.fetch(:entry)
        unless @migration_ownership.call(
          entry, "architecture-patrol", @migration_authority
        )
          raise ReservationBlocked.new("migration_ownership_changed")
        end
        migration = @migration_snapshot.call(entry, "architecture-patrol")
        unless migration.is_a?(Hash) &&
               migration["owner"] == @migration_authority.to_s &&
               migration["admission"] == true &&
               migration["epoch"].to_i.positive?
          raise ReservationBlocked.new("migration_ownership_changed")
        end
        phase = candidate.fetch(:action_phase, :discovery).to_sym
        store = %i[classification post_merge].include?(phase) ? nil : store_for(entry)
        aggregate = store&.read_job(candidate.fetch(:job_id))
        cfg = begin
          @config_loader.call(entry.fetch("path"))
        rescue StandardError => e
          evidence = {
            "name" => entry["name"].to_s,
            "path" => File.expand_path(entry.fetch("path")),
            "error" => "#{e.class}: #{e.message}"
          }
          unless %i[classification post_merge].include?(phase)
            block(
              entry, aggregate,
              reason: "project_config_unavailable", evidence: evidence,
              now: now, phase: phase
            )
          end
          raise ReservationBlocked.new("project_config_unavailable", evidence)
        end
        enabled = cfg.dig("daemon", "enabled") == true &&
                  Hive::Workflows.coding_id?(cfg["default_workflow"]) &&
                  (phase == :action || cfg.dig("refactor_patrol", "enabled") == true)
        unless enabled
          raise ReservationBlocked.new("architecture_patrol_disabled")
        end
        return reserve_classification(candidate, entry, cfg, now) if phase == :classification
        return reserve_post_merge(candidate, entry, cfg, now) if phase == :post_merge

        ownership = repository_ownership_decision(
          entry, aggregate, cfg: cfg, phase: phase,
          expected_identity: source_identity(aggregate)
        )
        if ownership.blocked?
          block(
            entry, aggregate, reason: ownership.reason,
            evidence: ownership.evidence, now: now, phase: phase
          )
          raise ReservationBlocked.new(ownership.reason, ownership.evidence)
        end
        manifest_path = candidate.fetch(:manifest_path)
        assert_manifest_matches!(manifest_path, aggregate)
        branch = cfg["default_branch"].to_s
        raise ReservationBlocked.new("missing_default_branch") if branch.empty?
        if phase == :discovery && @owner_process_start_time.to_s.empty?
          evidence = { "owner_pid" => @owner_pid }
          block(
            entry, aggregate, reason: "process_identity_unavailable",
            evidence: evidence, now: now, phase: phase
          )
          raise ReservationBlocked.new("process_identity_unavailable", evidence)
        end

        analysis_sha = begin
          @checkout_guard_factory.call(entry.fetch("path"), branch)
                                 .validate_and_snapshot!(
                                   merge_sha: aggregate.dig("source", "merge_sha"),
                                   analysis_sha: candidate[:batch_analysis_sha] || aggregate["analysis_sha"]
                                 ).fetch("analysis_sha")
        rescue Hive::RefactorPatrol::CheckoutGuard::SourceNoLongerOnTrunk => error
          retirement = if @dry_run
            :retired
          else
            @discovery_transitions.retire(
              entry: entry,
              store: store,
              aggregate: aggregate,
              merge_sha: error.merge_sha,
              trunk_sha: error.trunk_sha,
              now: now,
              claim_resolver: @claim_resolver
            )
          end
          if retirement == :retired || retirement == :already_terminal
            evidence = {
              "merge_sha" => error.merge_sha,
              "trunk_sha" => error.trunk_sha,
              "retirement" => retirement.to_s
            }
            @events << {
              status: :retired,
              project: entry.fetch("name"),
              job_id: aggregate.fetch("job_id"),
              reason: "source_no_longer_on_trunk",
              evidence: evidence
            }
            raise ReservationBlocked.new("source_no_longer_on_trunk", evidence)
          end
          raise unless phase == :action && retirement == :continuation_required

          aggregate = store.read_job(aggregate.fetch("job_id"))
          aggregate.fetch("analysis_sha")
        end

        capture = reserve_occurrence(
          store, entry, aggregate, migration, now
        )
        result_path = result_path_for(entry, aggregate.fetch("job_id"), phase)
        if phase == :action
          token = {
            kind: :architecture_patrol,
            phase: :action,
            job_id: aggregate.fetch("job_id"),
            registration: entry.fetch("name"),
            result_path: result_path,
            reservation_id: capture.occurrence_id,
            occurrence_id: capture.occurrence_id,
            migration_owner: migration.fetch("owner"),
            migration_epoch: migration.fetch("epoch"),
            job_digest: job_digest(aggregate)
          }
          return candidate.merge(
            slug: "#{PATROL_SLUG_PREFIX}-#{aggregate.fetch('job_id')}-actions",
            stage: PATROL_STAGE,
            command: "hive refactor-patrol #{Shellwords.escape(entry.fetch('name'))} " \
                     "--job-manifest #{Shellwords.escape(manifest_path)} " \
                     "--result-file #{Shellwords.escape(result_path)} " \
                     "--occurrence-id #{Shellwords.escape(capture.occurrence_id)} " \
                     "--actions --json",
            state_file_mtime: nil,
            state_file_path: nil,
            hive_state_path: entry["hive_state_path"],
            dispatch_token: token
          )
        end
        token = if @dry_run
          { job_id: aggregate.fetch("job_id"), owner: @owner, generation: 0, dry_run: true }
        else
          claim_discovery_through_gateway!(
            entry, store, capture, aggregate,
            analysis_sha: analysis_sha, now: now
          )
        end
        raise ReservationBlocked.new("claim_unavailable") unless token

        candidate.merge(
          slug: "#{PATROL_SLUG_PREFIX}-#{aggregate.fetch('job_id')}",
          stage: PATROL_STAGE,
          command: "hive refactor-patrol #{Shellwords.escape(entry.fetch('name'))} " \
                   "--job-manifest #{Shellwords.escape(manifest_path)} " \
                   "--result-file #{Shellwords.escape(result_path)} " \
                   "--occurrence-id #{Shellwords.escape(capture.occurrence_id)} --json",
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: entry["hive_state_path"],
          dispatch_token: token.merge(
            kind: :architecture_patrol, phase: :discovery,
            registration: entry.fetch("name"), result_path: result_path,
            analysis_sha: analysis_sha,
            reservation_id: capture.occurrence_id,
            occurrence_id: capture.occurrence_id,
            migration_owner: migration.fetch("owner"),
            migration_epoch: migration.fetch("epoch")
          )
        )
      rescue ReservationBlocked
        raise
      rescue Hive::GitError, Hive::RefactorPatrol::JobStore::Error, Hive::RefactorPatrol::PrManifest::Invalid,
             JSON::ParserError,
             SystemCallError, IOError, KeyError => e
        reason = e.is_a?(Hive::GitError) ? "checkout_guard" : "reservation_error"
        block(entry, aggregate || { "job_id" => candidate.fetch(:job_id), "source" => candidate.fetch(:source) },
              reason: reason, evidence: { "error" => "#{e.class}: #{e.message}" }, now: now,
              phase: phase)
        raise ReservationBlocked.new(reason, "error" => "#{e.class}: #{e.message}")
      end

      def spawned(dispatch, pid:, process_start_time:, pgid:, now: Time.now)
        return dispatch if @dry_run
        return dispatch if %i[action classification].include?(dispatch.dig(:dispatch_token, :phase))

        @claim_maintenance_transitions.attach_discovery(
          store: store_for(dispatch.fetch(:entry)),
          token: dispatch.fetch(:dispatch_token),
          pid: pid,
          process_start_time: process_start_time,
          pgid: pgid,
          now: now,
          lease_sec: @lease_sec
        )
      end

      def cancel(dispatch, reason:, now: Time.now)
        token = dispatch[:dispatch_token]
        return unless token
        return dispatch if @dry_run || token[:dry_run]
        return dispatch if token[:phase] == :action
        if token[:phase] == :classification
          entry = dispatch.fetch(:entry)
          classifier_for(entry, @config_loader.call(entry.fetch("path"))).release_claim!(
            token.fetch(:classification_occurrence_id),
            reservation_id: token.fetch(:reservation_id), now: now
          )
          return dispatch
        end

        entry = dispatch.fetch(:entry)
        store = store_for(entry)
        release_discovery_through_gateway!(
          entry, store, token, reason: reason, now: now,
          backoff_sec: RETRY_BACKOFF_SEC
        )
      rescue Hive::RefactorPatrol::JobStore::StaleClaim
        nil
      end

      def complete(dispatch_token:, exit_code:, envelope:, now: Time.now)
        return completion_result(:dry_run, dispatch_token, envelope) if @dry_run || dispatch_token[:dry_run]
        return complete_action(dispatch_token, exit_code, envelope, now) if dispatch_token[:phase] == :action
        return complete_classification(dispatch_token, exit_code, now) if
          dispatch_token[:phase] == :classification

        entry = entry_for_token(dispatch_token)
        store = store_for(entry)
        aggregate = store.read_job(dispatch_token.fetch(:job_id))
        unless exit_code == 0 && envelope.is_a?(Hash) && valid_report_envelope?(envelope)
          aggregate = release_discovery_through_gateway!(
            entry, store, dispatch_token,
            reason: completion_failure_reason(exit_code, envelope),
            now: now, backoff_sec: RETRY_BACKOFF_SEC
          )
          result = completion_result(
            :retry, dispatch_token, envelope, aggregate: aggregate
          )
          publish_finalized(entry, dispatch_token, result, aggregate, now)
          return result
        end

        aggregate = checkpoint_discovery_through_gateway!(
          entry, store, dispatch_token,
          envelope: envelope, now: now,
          backoff_sec: discovery_retry_backoff_sec(envelope, now)
        )
        result = completion_result(
          if envelope.fetch("complete")
            aggregate.fetch("complete") ? :closed : :classified
          else
            :retry
          end,
          dispatch_token, envelope, aggregate: aggregate
        )
        publish_finalized(entry, dispatch_token, result, aggregate, now)
        result
      rescue Hive::RefactorPatrol::JobStore::StaleClaim
        completion_result(:stale, dispatch_token, envelope, aggregate: aggregate)
      rescue Hive::RefactorPatrol::EffectGateway::Denied => e
        raise unless e.reason == "stale_claim"

        aggregate = store&.read_job(dispatch_token.fetch(:job_id))
        completion_result(
          :stale, dispatch_token, envelope, aggregate: aggregate
        )
      rescue Hive::RefactorPatrol::JobStore::Error, KeyError
        begin
          if entry && store
            release_discovery_through_gateway!(
              entry, store, dispatch_token,
              reason: "mismatched_completion", now: now,
              backoff_sec: RETRY_BACKOFF_SEC
            )
          end
        rescue Hive::RefactorPatrol::JobStore::Error
          nil
        end
        completion_result(:retry, dispatch_token, envelope, aggregate: aggregate)
      end

      private

      def claim_discovery_through_gateway!(entry, store, capture, aggregate,
                                           analysis_sha:, now:)
        @discovery_transitions.claim(
          entry: entry,
          store: store,
          capture: capture,
          aggregate: aggregate,
          analysis_sha: analysis_sha,
          now: now
        )
      end

      def release_discovery_through_gateway!(entry, store, token, reason:,
                                             now:, backoff_sec:)
        @discovery_transitions.release(
          entry: entry,
          store: store,
          token: token,
          reason: reason,
          now: now,
          backoff_sec: backoff_sec
        )
      end

      def checkpoint_discovery_through_gateway!(entry, store, token,
                                                envelope:, now:, backoff_sec:)
        @discovery_transitions.checkpoint(
          entry: entry,
          store: store,
          token: token,
          envelope: envelope,
          now: now,
          backoff_sec: backoff_sec
        )
      end

      def block_through_gateway!(entry, store, aggregate, phase:, reason:,
                                 evidence:, now:, backoff_sec:)
        @discovery_transitions.block(
          entry: entry,
          store: store,
          aggregate: aggregate,
          phase: phase,
          reason: reason,
          evidence: evidence,
          now: now,
          backoff_sec: backoff_sec
        )
      end

      def reserve_occurrence(store, entry, aggregate, migration, now)
        @occurrence_lifecycle.reserve(
          store: store,
          entry: entry,
          aggregate: aggregate,
          migration: migration,
          now: now
        )
      end

      def managed_entries
        @configuration_errors = []
        Array(@registry.call).filter_map do |entry|
          next unless @migration_ownership.call(entry, "architecture-patrol", @migration_authority)

          cfg = @config_loader.call(entry.fetch("path"))
          next unless cfg.dig("daemon", "enabled") == true
          next unless Hive::Workflows.coding_id?(cfg["default_workflow"])

          entry.merge("_refactor_patrol_cfg" => cfg)
        rescue StandardError => e
          @configuration_errors << {
            entry: entry,
            evidence: {
              "name" => entry["name"].to_s,
              "path" => File.expand_path(entry.fetch("path")),
              "error" => "#{e.class}: #{e.message}"
            }
          }
          nil
        end
      end

      def block_configuration_errors(now)
        Array(@configuration_errors).each do |item|
          entry = item.fetch(:entry)
          store = store_for(entry)
          work = store.claimable_jobs(now: now).map { |job| [ job, :discovery ] } +
                 store.actionable_jobs(now: now).map { |job| [ job, :action ] }
          work.each do |aggregate, phase|
            block(
              entry, aggregate,
              reason: "project_config_unavailable",
              evidence: item.fetch(:evidence),
              now: now,
              phase: phase
            )
          end
        rescue Hive::RefactorPatrol::JobStore::Error, KeyError, SystemCallError => e
          @events << {
            status: :blocked,
            project: entry && entry["name"],
            reason: "project_config_unavailable",
            error: "#{e.class}: #{e.message}"
          }
        end
      end

      def store_for(entry)
        return @job_store_factory.call(entry.fetch("path")) if @job_store_factory

        Hive::RefactorPatrol::JobStore.new(
          entry.fetch("path"),
          hive_state_path: entry.fetch("hive_state_path")
        )
      end

      def classifier_for(entry, cfg = entry.fetch("_refactor_patrol_cfg"))
        return @classifier_factory.call(entry, cfg) if @classifier_factory

        state_root = entry["hive_state_path"] || File.join(entry.fetch("path"), ".hive-state")
        state = Hive::RefactorPatrol::StateStore.new(
          entry.fetch("path"), hive_state_path: state_root
        )
        Hive::RefactorPatrol::MergeClassifier.new(
          root: File.join(state_root, "refactor_patrol", "v2", "merge-classifications"),
          decision_provider: lambda do |prompt|
            Hive::RefactorPatrol::MergeClassifierRunner.new(
              project_root: entry.fetch("path"), cfg: cfg, state: state
            ).call(prompt)
          end
        )
      end

      def post_merge_batch_store_for(entry)
        return @post_merge_batch_store_factory.call(entry) if @post_merge_batch_store_factory

        Hive::RefactorPatrol::PostMergeBatchStore.new(
          root: File.join(
            entry.fetch("hive_state_path"), "refactor_patrol", "v2", "post-merge-batches"
          )
        )
      end

      def recover_post_merge_batches(entry, store, now)
        return if @dry_run

        post_merge_batch_store_for(entry).pending(limit: 100).each do |batch|
          materialize_batch_record(entry, store, batch, now)
        rescue StandardError => error
          @events << {
            status: :blocked, project: entry.fetch("name"),
            batch_id: batch["batch_id"], reason: "post_merge_batch_recovery_failed",
            error: "#{error.class}: #{error.message}"[0, 2_000]
          }
        end
      end

      def materialize_batch_record(entry, store, batch, now)
        cfg = entry.fetch("_refactor_patrol_cfg") do
          @config_loader.call(entry.fetch("path"))
        end
        resolver = if @manifest_resolver_factory
          @manifest_resolver_factory.call(entry, cfg)
        else
          Hive::RefactorPatrol::PrManifestResolver.new(
            project_root: entry.fetch("path"), registration: entry.fetch("name"),
            default_branch: cfg.fetch("default_branch"), cfg: cfg,
            hive_state_path: entry["hive_state_path"]
          )
        end
        classifier = classifier_for(entry, cfg)
        occurrence_ids = batch.fetch("members").map { |member| member.fetch("occurrence_id") }.uniq
        classifications = occurrence_ids.map do |occurrence_id|
          classifier.fetch_occurrence(occurrence_id) ||
            raise(Hive::RefactorPatrol::MergeClassifier::Invalid, "batch classification is missing")
        end
        manifest = resolver.materialize_batch(batch, classifications: classifications)
        aggregate = @architecture_intake_transitions.enqueue(
          entry: entry, store: store, manifest: manifest,
          policy: Hive::RefactorPatrol::Policy.capture(cfg, now: now),
          now: now, dry_run: false
        )
        @event_publisher.pull_request_merged(entry, manifest)
        batch_store = post_merge_batch_store_for(entry)
        batch_store.mark_materialized!(
          batch.fetch("batch_id"), job_id: manifest.fetch("job_id"),
          manifest_checksum: manifest.fetch("manifest_checksum"), now: now
        )
        classifications.each do |classification|
          binding = batch_store.materialization_binding(
            classification.merge("registration" => entry.fetch("name"))
          )
          next unless binding

          classifier.bind_materialization!(
            classification.fetch("occurrence_id"),
            job_ids: binding.fetch("job_ids"),
            manifest_checksums: binding.fetch("manifest_checksums"), now: now
          )
        end
        batch_store.finalize!(
          batch.fetch("batch_id"), job_id: manifest.fetch("job_id"),
          manifest_checksum: manifest.fetch("manifest_checksum")
        )
        { aggregate: aggregate, manifest_path: resolver.manifest_path(manifest.fetch("job_id")) }
      end

      def classification_work(entry, store, now)
        records = classifier_for(entry).eligible_records(now: now, limit: 100)
        features = records.select do |record|
          record.fetch("status") == "feature" && !record["materialization"]
        end
        unclaimed = post_merge_batch_store_for(entry).unclaimed_occurrence_ids(
          features.map { |record| record.merge("registration" => entry.fetch("name")) }
        )
        records.filter_map do |record|
          case record.fetch("status")
          when "feature"
            next if record["materialization"]
            next unless unclaimed.include?(record.fetch("occurrence_id"))

            { classification: record, phase: :post_merge }
          when "pending"
            { classification: record, phase: :classification }
          when "retry_wait"
            retry_at = record["retry_at"] && Time.iso8601(record.fetch("retry_at"))
            { classification: record, phase: :classification } if !retry_at || retry_at <= now
          end
        rescue StandardError => error
          @events << {
            status: :blocked, project: entry.fetch("name"),
            occurrence_id: record["occurrence_id"], reason: "classification_admission_failed",
            error: "#{error.class}: #{error.message}"[0, 2_000]
          }
          nil
        end
      end

      def reserve_post_merge(candidate, entry, cfg, now)
        raise ReservationBlocked.new("post_merge_would_batch") if @dry_run

        classifier = classifier_for(entry, cfg)
        primary = classifier.fetch_occurrence(
          candidate.fetch(:classification_occurrence_id)
        )
        unless primary && primary.fetch("status") == "feature" &&
               primary.fetch("decision") == "feature" && !primary["materialization"]
          raise ReservationBlocked.new("post_merge_classification_changed")
        end
        branch = cfg["default_branch"].to_s
        raise ReservationBlocked.new("missing_default_branch") if branch.empty?
        analysis_sha = @checkout_guard_factory.call(entry.fetch("path"), branch)
          .validate_and_snapshot!(
            merge_sha: primary.dig("snapshot", "merge_sha"), analysis_sha: nil
          ).fetch("analysis_sha")

        records = post_merge_candidates(classifier, primary, entry, now)
        unique_paths = records.flat_map { |record| record.dig("snapshot", "changed_paths") }.uniq
        mapping = @post_merge_slice_mapper.call(
          entry: entry, cfg: cfg, analysis_sha: analysis_sha, paths: unique_paths
        )
        by_path = mapping.path_mappings.to_h { |item| [ item.fetch("path"), item ] }
        mappings = records.to_h do |record|
          [
            record.fetch("occurrence_id"),
            record.dig("snapshot", "changed_paths").map { |path| by_path.fetch(path) }
          ]
        end

        fresh = records.filter_map do |record|
          current = classifier.fetch_occurrence(record.fetch("occurrence_id"))
          next unless current == record.reject { |key, _value| key == "registration" }

          current.merge("registration" => entry.fetch("name"))
        end
        unless fresh.any? { |record| record.fetch("occurrence_id") == primary.fetch("occurrence_id") }
          raise ReservationBlocked.new("post_merge_classification_changed")
        end
        fresh_ids = fresh.map { |record| record.fetch("occurrence_id") }
        mappings.select! { |occurrence_id, _value| fresh_ids.include?(occurrence_id) }
        batch = post_merge_batch_store_for(entry).claim!(
          primary_occurrence_id: primary.fetch("occurrence_id"),
          classifications: fresh, analysis_sha: analysis_sha,
          mappings: mappings, now: now
        )
        materialized = materialize_batch_record(entry, store_for(entry), batch, now)
        owner_candidate = candidate_for(
          entry, materialized.fetch(:aggregate), phase: :discovery
        ).merge(batch_analysis_sha: analysis_sha)
        reserve(owner_candidate, now: now)
      rescue Hive::RefactorPatrol::PostMergeBatchStore::Conflict
        batch = post_merge_batch_store_for(entry)
          .batches_for_occurrence(candidate.fetch(:classification_occurrence_id))
          .reject { |record| record.fetch("status") == "finalized" }.last
        raise ReservationBlocked.new("post_merge_batch_claim_changed") unless batch

        materialized = materialize_batch_record(entry, store_for(entry), batch, now)
        reserve(
          candidate_for(entry, materialized.fetch(:aggregate), phase: :discovery)
            .merge(batch_analysis_sha: batch.fetch("analysis_sha")),
          now: now
        )
      rescue Hive::RefactorPatrol::CheckoutGuard::SourceNoLongerOnTrunk => error
        @events << {
          status: :blocked, project: entry.fetch("name"),
          occurrence_id: candidate[:classification_occurrence_id],
          reason: "source_no_longer_on_trunk",
          evidence: { "merge_sha" => error.merge_sha, "trunk_sha" => error.trunk_sha }
        }
        raise ReservationBlocked.new("source_no_longer_on_trunk")
      rescue Hive::GitError, Hive::RefactorPatrol::JobStore::Error,
             Hive::RefactorPatrol::PrManifest::Invalid,
             Hive::RefactorPatrol::PrManifestResolver::Conflict,
             SystemCallError, IOError, KeyError => error
        @events << {
          status: :blocked, project: entry.fetch("name"),
          occurrence_id: candidate[:classification_occurrence_id],
          reason: "post_merge_batch_materialization_failed",
          error: "#{error.class}: #{error.message}"[0, 2_000]
        }
        raise ReservationBlocked.new(
          "post_merge_batch_materialization_failed", "error" => error.message
        )
      end

      def post_merge_candidates(classifier, primary, entry, now)
        primary_time = parse_time(primary.dig("snapshot", "merged_at"))
        records = classifier.eligible_records(now: now, limit: 100).select do |record|
          record.fetch("status") == "feature" && !record["materialization"] &&
            record.dig("snapshot", "repository") == primary.dig("snapshot", "repository") &&
            (parse_time(record.dig("snapshot", "merged_at")) - primary_time).abs <=
              Hive::RefactorPatrol::PostMergeBatchStore::WINDOW_SEC
        end
        records.unshift(primary) unless records.any? do |record|
          record.fetch("occurrence_id") == primary.fetch("occurrence_id")
        end
        ordered = [ primary ] + records.reject do |record|
          record.fetch("occurrence_id") == primary.fetch("occurrence_id")
        end
        paths = 0
        ordered.first(Hive::RefactorPatrol::PostMergeBatchStore::MAX_CANDIDATES)
          .take_while do |record|
            paths += record.dig("snapshot", "changed_paths").size
            paths <= Hive::RefactorPatrol::MergeClassifier::MAX_FILES
          end
          .map { |record| record.merge("registration" => entry.fetch("name")) }
      end

      def reserve_classification(candidate, entry, cfg, now)
        classifier = classifier_for(entry, cfg)
        reservation_id = Digest::SHA256.hexdigest(
          [ @owner, candidate.fetch(:classification_occurrence_id), SecureRandom.hex(16) ].join("\0")
        )
        record = classifier.claim!(
          candidate.fetch(:classification_occurrence_id),
          reservation_id: reservation_id, owner: @owner, now: now,
          lease_sec: @lease_sec
        )
        state_root = entry["hive_state_path"] || File.join(entry.fetch("path"), ".hive-state")
        result_path = File.join(
          state_root, "refactor_patrol", "v2", "results",
          "classification-#{record.fetch('occurrence_id')}-#{SecureRandom.hex(8)}.json"
        )
        token = {
          kind: :architecture_patrol, phase: :classification,
          registration: entry.fetch("name"),
          classification_occurrence_id: record.fetch("occurrence_id"),
          reservation_id: reservation_id,
          result_path: result_path
        }
        candidate.merge(
          slug: "#{PATROL_SLUG_PREFIX}-classification-#{record.fetch('occurrence_id')[0, 12]}",
          stage: PATROL_STAGE,
          command: "hive refactor-patrol-classify #{Shellwords.escape(entry.fetch('name'))} " \
                   "--occurrence-id #{record.fetch('occurrence_id')} " \
                   "--reservation-id #{reservation_id} " \
                   "--result-file #{Shellwords.escape(result_path)} --json",
          state_file_mtime: nil, state_file_path: nil,
          hive_state_path: entry["hive_state_path"], dispatch_token: token
        )
      rescue Hive::RefactorPatrol::MergeClassifier::Conflict,
             Hive::RefactorPatrol::MergeClassifier::Retryable => error
        raise ReservationBlocked.new(
          "classification_claim_unavailable", "error" => error.message
        )
      end

      def complete_classification(token, _exit_code, now)
        entry = entry_for_registration(token.fetch(:registration))
        classifier = classifier_for(
          entry, @config_loader.call(entry.fetch("path"))
        )
        record = classifier.fetch_occurrence(token.fetch(:classification_occurrence_id))
        return { status: :blocked, reason: "classification_occurrence_missing" } unless record

        if record["claim"]&.fetch("reservation_id", nil) == token.fetch(:reservation_id)
          record = classifier.release_claim!(
            record.fetch("occurrence_id"), reservation_id: token.fetch(:reservation_id), now: now
          )
        end

        status = case record.fetch("status")
        when "feature" then :classified
        when "skip" then :closed
        when "blocked" then :blocked
        else :retry
        end
        {
          status: status, phase: :classification,
          occurrence_id: record.fetch("occurrence_id"),
          reason: record.fetch("reason")
        }
      rescue StandardError => error
        {
          status: :blocked, phase: :classification,
          occurrence_id: token[:classification_occurrence_id],
          reason: "classification_completion_failed",
          error: "#{error.class}: #{error.message}"[0, 2_000]
        }
      end

      def discovery_available?(entry)
        cfg = entry.fetch("_refactor_patrol_cfg")
        cfg.dig("refactor_patrol", "enabled") == true
      end

      def result_path_for(entry, job_id, phase)
        File.join(
          entry.fetch("hive_state_path"), "refactor_patrol", "v2", "results",
          "#{job_id}-#{phase}-#{SecureRandom.hex(8)}.json"
        )
      end

      def continuation_evidence?(aggregate)
        Hive::RefactorPatrol::RepositoryOwnership.continuation_evidence?(aggregate)
      end

      def repository_ownership_decision(entry, aggregate,
                                        cfg: entry.fetch("_refactor_patrol_cfg"),
                                        phase: :discovery,
                                        expected_identity: nil,
                                        ownership_resolver: @repository_ownership)
        decision = ownership_resolver.call(
          entry: entry,
          cfg: cfg,
          expected_identity: expected_identity,
          continuation: continuation_evidence?(aggregate),
          continuation_owner: Hive::RefactorPatrol::RepositoryOwnership
            .remote_continuation_evidence?(aggregate)
        )
        if phase.to_sym == :action && decision.reason == "architecture_patrol_disabled"
          return Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
            authority: :continuation_only,
            reason: decision.reason,
            evidence: decision.evidence
          )
        end

        decision
      end

      def source_identity(aggregate)
        Hive::RefactorPatrol::RepositoryOwnership.identity_from_source(
          aggregate.fetch("source")
        )
      end

      def candidate_for(entry, aggregate, phase:)
        source = aggregate.fetch("source")
        {
          project: entry.fetch("name"), patrol_kind: :architecture,
          action_phase: phase,
          job_id: aggregate.fetch("job_id"), pr_number: source.fetch("number"),
          pr_url: source.fetch("url"), merged_at: source["merged_at"],
          source: source, entry: entry,
          slug: "#{PATROL_SLUG_PREFIX}-#{aggregate.fetch('job_id')}", stage: PATROL_STAGE,
          manifest_path: File.join(
            entry.fetch("hive_state_path"), "refactor_patrol", "v2", "manifests",
            "#{aggregate.fetch('job_id')}.json"
          )
        }
      end

      def candidate_for_classification(entry, record, phase: :classification)
        snapshot = record.fetch("snapshot")
        label = phase == :post_merge ? "post-merge" : "classification"
        {
          project: entry.fetch("name"), patrol_kind: :architecture,
          action_phase: phase,
          job_id: "#{label}-#{record.fetch('occurrence_id')[0, 24]}",
          classification_occurrence_id: record.fetch("occurrence_id"),
          pr_number: snapshot.fetch("number"), pr_url: snapshot.fetch("url"),
          merged_at: snapshot.fetch("merged_at"), entry: entry,
          slug: "#{PATROL_SLUG_PREFIX}-#{label}-#{record.fetch('occurrence_id')[0, 12]}",
          stage: PATROL_STAGE
        }
      end

      def block(entry, aggregate, reason:, evidence:, now:, phase: :discovery)
        unless @dry_run
          store = store_for(entry)
          block_through_gateway!(
            entry, store, aggregate, phase: phase,
            reason: reason, evidence: evidence, now: now,
            backoff_sec: retry_backoff_sec(phase)
          )
        end
        @events << {
          status: :blocked, project: entry.fetch("name"), job_id: aggregate.fetch("job_id"),
          pr_number: aggregate.dig("source", "number"), pr_url: aggregate.dig("source", "url"),
          reason: reason, evidence: evidence
        }
      rescue Hive::RefactorPatrol::JobStore::Error => e
        @events << { status: :blocked, project: entry.fetch("name"), reason: reason, error: e.message }
      end

      def effect_capacity_exhaustion(store, aggregate, phase:, now:)
        occurrence = store.occurrence_for_job(aggregate.fetch("job_id"))
        return unless occurrence
        count = occurrence.fetch("effects").size
        limit = Hive::Modules::Migration::PatrolEvidence::MAX_EFFECTS_PER_OCCURRENCE
        reserve = effect_capacity_reserve(phase)
        return if count < limit - reserve
        return if blocking_claim_for_occurrence?(
          aggregate, occurrence.fetch("occurrence_id"), now: now
        )

        {
          "occurrence_id" => occurrence.fetch("occurrence_id"),
          "effect_count" => count,
          "effect_limit" => limit,
          "reserved_effects" => reserve
        }
      end

      def effect_capacity_reserve(phase)
        return ACTION_EFFECT_CAPACITY_RESERVE if phase.to_sym == :action

        Hive::RefactorPatrol::DiscoveryCapacity::MAX_EFFECTS_PER_CLAIM
      end

      def rollover_effect_capacity(entry, store, aggregate, evidence, now)
        updated = Hive::Modules::Migration::Patrols.with_migration_lock(
          entry.fetch("path"),
          hive_state_path: entry["hive_state_path"],
          shared: true
        ) do
          assert_rollover_admission!(entry, store, aggregate)
          @occurrence_lifecycle.rollover(
            store: store,
            entry: entry,
            aggregate: aggregate,
            now: now,
            claim_liveness_resolver: @claim_liveness_resolver
          )
        end
        @events << {
          status: :recovered,
          project: entry.fetch("name"),
          job_id: aggregate.fetch("job_id"),
          pr_number: aggregate.dig("source", "number"),
          pr_url: aggregate.dig("source", "url"),
          reason: "effect_capacity_rolled_over",
          evidence: evidence.merge(
            "successor_occurrence_id" =>
              updated.fetch("occurrence_id")
          )
        }
        updated
      rescue Hive::ConfigError,
             Hive::RefactorPatrol::JobStore::Error => e
        @events << {
          status: :blocked,
          project: entry.fetch("name"),
          job_id: aggregate.fetch("job_id"),
          pr_number: aggregate.dig("source", "number"),
          pr_url: aggregate.dig("source", "url"),
          reason: "effect_capacity_rollover_failed",
          evidence: evidence.merge(
            "error" => "#{e.class}: #{e.message}"
          )
        }
        nil
      end

      def blocking_claim_for_occurrence?(aggregate, occurrence_id, now:)
        discovery = aggregate.fetch("attempts").reverse_each.find do |attempt|
          attempt["kind"] ==
            Hive::RefactorPatrol::JobStore::DISCOVERY_ATTEMPT_KIND &&
            attempt["occurrence_id"] == occurrence_id &&
            Hive::RefactorPatrol::JobStore::ACTIVE_CLAIM_STATES.include?(
              attempt["state"]
            )
        end
        if discovery
          return true if @dry_run

          resolved = begin
            @claim_liveness_resolver&.call(discovery) == :resolved
          rescue StandardError
            false
          end
          return true unless resolved
        end

        aggregate.fetch("actions").any? do |action|
          Array(action["claims"]).any? do |claim|
            claim["occurrence_id"] == occurrence_id &&
              Hive::RefactorPatrol::JobStore::
                ACTIVE_ACTION_CLAIM_STATES.include?(claim["state"])
          end
        end
      rescue ArgumentError, KeyError
        true
      end

      def assert_rollover_admission!(entry, store, aggregate)
        migration = @migration_snapshot.call(
          entry, "architecture-patrol"
        )
        capture = store.occurrence_capture(aggregate.fetch("job_id"))
        admitted = @migration_ownership.call(
          entry, "architecture-patrol", @migration_authority
        ) && migration.is_a?(Hash) &&
          migration["owner"] == @migration_authority.to_s &&
          migration["admission"] == true &&
          migration["epoch"].to_i.positive? && capture &&
          capture.owner == migration.fetch("owner") &&
          capture.owner_epoch == migration.fetch("epoch")
        return true if admitted

        raise Hive::ConfigError,
              "architecture patrol migration ownership changed"
      end

      def assert_manifest_matches!(path, aggregate)
        manifest = Hive::RefactorPatrol::PrManifest.load!(
          path,
          expected_job_id: aggregate.fetch("job_id"),
          registration: aggregate.dig("source", "registration"),
          default_branch: aggregate.dig("source", "base_branch")
        )
        source = manifest.fetch("source").merge(
          "changed_paths" => manifest.fetch("changed_paths"),
          "manifest_checksum" => manifest.fetch("manifest_checksum")
        )
        if manifest.fetch("schema_version") == Hive::RefactorPatrol::PrManifest::SCHEMA_VERSION
          source.merge!(
            "lane" => manifest.fetch("lane"),
            "classification" => manifest.fetch("classification"),
            "provenance" => manifest.fetch("provenance")
          )
        end
        unless manifest["job_id"] == aggregate.fetch("job_id") && source == aggregate.fetch("source")
          raise Hive::RefactorPatrol::JobStore::InconsistentRecord,
                "published manifest does not match authoritative job"
        end
      end

      def entry_for_token(token)
        registration = token.fetch(:registration)
        entry = entry_for_registration(registration)
        aggregate = store_for(entry).read_job(token.fetch(:job_id))
        unless aggregate.dig("source", "registration") == registration
          raise Hive::RefactorPatrol::JobStore::InconsistentRecord,
                "claimed refactor patrol job registration does not match its token"
        end
        entry
      end

      def entry_for_registration(registration)
        entry = Array(@registry.call).find { |candidate| candidate.fetch("name") == registration }
        raise Hive::RefactorPatrol::JobStore::RecordNotFound, "claimed refactor patrol job registration not found" unless entry
        entry
      end

      def completion_failure_reason(exit_code, envelope)
        return "child_failed_or_signaled" unless exit_code == 0
        return "missing_envelope" if envelope.nil?

        "malformed_envelope"
      end

      def complete_action(token, exit_code, envelope, now)
        entry = entry_for_token(token)
        store = store_for(entry)
        aggregate = store.read_job(token.fetch(:job_id))
        valid = exit_code == 0 && envelope.is_a?(Hash) && valid_report_envelope?(envelope) &&
                envelope["job_id"] == aggregate.fetch("job_id") &&
                envelope["project"] == entry.fetch("name") &&
                envelope["project_root"] == entry.fetch("path") &&
                envelope["source_pr"] == aggregate.fetch("source") &&
                envelope["analysis_sha"] == aggregate.fetch("analysis_sha") &&
                envelope["complete"] == aggregate.fetch("complete")
        status = if valid && aggregate.fetch("complete")
          :closed
        elsif valid && action_progressed?(token, aggregate)
          :action_pending
        elsif valid
          aggregate = block_through_gateway!(
            entry, store, aggregate, phase: :action,
            reason: "action_no_progress", evidence: {}, now: now,
            backoff_sec: RUNAWAY_RETRY_BACKOFF_SEC
          )
          :retry
        else
          aggregate = block_through_gateway!(
            entry, store, aggregate, phase: :action,
            reason: action_completion_failure_reason(exit_code, envelope),
            evidence: {},
            now: now,
            backoff_sec: RUNAWAY_RETRY_BACKOFF_SEC
          )
          :retry
        end
        result = completion_result(status, token, envelope, aggregate: aggregate)
        publish_finalized(entry, token, result, aggregate, now)
        result
      rescue Hive::RefactorPatrol::JobStore::Error, Hive::ConfigError, KeyError
        completion_result(:retry, token, envelope, aggregate: aggregate)
      end

      def action_completion_failure_reason(exit_code, envelope)
        return "action_child_failed_or_signaled" unless exit_code == 0
        return "action_missing_envelope" if envelope.nil?

        "action_malformed_or_mismatched_envelope"
      end

      def action_progressed?(token, aggregate)
        baseline = token[:job_digest] || token["job_digest"]
        baseline.nil? || baseline != job_digest(aggregate)
      end

      def job_digest(aggregate)
        Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalJSON.generate(aggregate)
        )
      end

      def retry_backoff_sec(phase)
        phase.to_sym == :action ? RUNAWAY_RETRY_BACKOFF_SEC : RETRY_BACKOFF_SEC
      end

      def discovery_retry_backoff_sec(envelope, now)
        reasons = Array(envelope["review_errors"]).filter_map do |error|
          error.dig("details", "resource_exhaustion", "reason") if error.is_a?(Hash)
        end
        fallback = if reasons.any? { |reason| DEFERRED_RESOURCE_EXHAUSTION_REASONS.include?(reason) }
          RUNAWAY_RETRY_BACKOFF_SEC
        else
          RETRY_BACKOFF_SEC
        end
        Hive::Patrol::LaunchBudget.resource_exhaustion_backoff_sec(
          reasons, now: now, fallback: fallback
        )
      end

      def valid_report_envelope?(envelope)
        @schemers[envelope["schema_version"]]&.valid?(envelope) == true
      end

      def completion_result(status, token, envelope, aggregate: nil)
        source = aggregate && aggregate["source"]
        dispositions = aggregate && aggregate["dispositions"]
        actions = Array(aggregate && aggregate["actions"])
        use_envelope = %i[closed classified action_pending].include?(status) && envelope.is_a?(Hash)
        {
          status: status, job_id: token[:job_id],
          pr_number: source && source["number"], pr_url: source && source["url"],
          fix_count: use_envelope ? Array(envelope["fix"]).size : Array(dispositions && dispositions["fix"]).size,
          discuss_count: use_envelope ? Array(envelope["discuss"]).size : Array(dispositions && dispositions["discuss"]).size,
          dismiss_count: use_envelope ? Array(envelope["dismiss"]).size : Array(dispositions && dispositions["dismiss"]).size,
          action_count: actions.size,
          terminal_action_count: actions.count { |action| action["terminal"] == true },
          pending_action_ids: actions.reject { |action| action["terminal"] == true }
                                     .map { |action| action["canonical_action_id"] }.compact,
          action_outcomes: actions.to_h do |action|
            [ action["canonical_action_id"], action["outcome"] ]
          end.compact
        }
      end

      def publish_finalized(entry, token, result, aggregate, now)
        store = store_for(entry)
        @occurrence_lifecycle.publish_finalized(
          store: store,
          entry: entry,
          token: token,
          result: result,
          aggregate: aggregate,
          now: now
        )
      end

      def recover_occurrences(store, entry, now)
        project = entry.fetch("name")
        backoff = store.recovery_backoff(now: now)
        return false if backoff.fetch("blocked")
        expected_generation = backoff.fetch("generation")

        @occurrence_lifecycle.recover(
          store: store, entry: entry, now: now
        ) do |aggregate|
          @discovery_transitions.reconcile_recorded(
            entry, store, aggregate, now
          )
        end
        store.clear_recovery_failure!(
          expected_generation: expected_generation
        )
      rescue Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle::
               RecoveryError => e
        failure = begin
          store.record_recovery_failure!(
            operation: "architecture_occurrence",
            occurrence_id: e.occurrence_id,
            job_id: e.job_id,
            error: e.cause || e,
            now: now
          )
        rescue StandardError
          nil
        end
        unless failure
          return recovery_state_unavailable(
            entry, e.cause || e,
            occurrence_id: e.occurrence_id,
            job_id: e.job_id
          )
        end
        recovery_failure_event(
          project: project,
          occurrence_id: e.occurrence_id,
          job_id: e.job_id,
          failure: failure,
          now: now
        )
        false
      rescue StandardError => e
        failure = begin
          store.record_recovery_failure!(
            operation: "architecture_occurrence",
            error: e,
            now: now
          )
        rescue StandardError
          nil
        end
        return recovery_state_unavailable(entry, e) unless failure

        recovery_failure_event(
          project: project,
          occurrence_id: nil,
          job_id: nil,
          failure: failure,
          now: now
        )
        false
      end

      def recovery_failure_event(project:, occurrence_id:, job_id:,
                                 failure:, now:)
        retry_at = Time.iso8601(
          failure.fetch("next_eligible_at")
        )
        interval = [ (retry_at - now).to_i, 0 ].max
        @events << {
          status: :blocked,
          project: project,
          occurrence_id: occurrence_id,
          job_id: job_id,
          recovery: "architecture_occurrence",
          blocker: "recovery_failed",
          error_class: failure.fetch("error_class"),
          error: failure.fetch("error_message"),
          retry_count: failure.fetch("failure_count"),
          recovery_generation: failure.fetch("generation"),
          retry_in_sec: interval,
          retry_at: retry_at.utc.iso8601
        }
      end

      def recovery_state_unavailable(entry, error, occurrence_id: nil,
                                     job_id: nil)
        diagnostic =
          Hive::Modules::Migration::OccurrenceJournalState
          .normalize_error(error)
        @events << {
          status: :blocked,
          project: entry && entry["name"],
          occurrence_id: occurrence_id,
          job_id: job_id,
          recovery: "architecture_occurrence",
          blocker: "recovery_state_unavailable",
          error_class: diagnostic.fetch("error_class"),
          error: diagnostic.fetch("error_message")
        }
        false
      end

      def parse_time(value)
        value ? Time.iso8601(value.to_s).utc : Time.at(0).utc
      rescue ArgumentError
        Time.at(0).utc
      end
    end
  end
end
