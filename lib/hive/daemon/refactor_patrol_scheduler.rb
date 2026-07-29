require "json"
require "json_schemer"
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
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/architecture_occurrence_lifecycle"
require "hive/refactor_patrol/claim_maintenance_transitions"
require "hive/refactor_patrol/discovery_transitions"
require "hive/refactor_patrol/pr_manifest"
require "hive/refactor_patrol/process_group_resolver"
require "hive/refactor_patrol/repository_ownership"
require "hive/modules/event_publisher"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"

module Hive
  module Daemon
    # Exposes durable merged-PR architecture work to PatrolArbiter and owns
    # the discovery claim/fence lifecycle around its child process.
    class RefactorPatrolScheduler
      PATROL_STAGE = "refactor-patrol".freeze
      PATROL_SLUG_PREFIX = "refactor-patrol".freeze
      MODULE_SCHEDULE = "*/10 * * * *".freeze
      RETRY_BACKOFF_SEC = 60
      SUPPORTED_REPORT_SCHEMA_VERSIONS = [ 2, Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol") ].uniq.freeze

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
                     job_store_factory: ->(path) { Hive::RefactorPatrol::JobStore.new(path) },
                     checkout_guard_factory: nil, repository_resolver: nil,
                     repository_ownership: nil,
                     owner: nil, claim_resolver: ProcessGroupResolver.new,
                     lease_sec: 7200, dry_run: false,
                     migration_authority: :legacy, migration_ownership: nil,
                     migration_snapshot: nil, evidence_store_factory: nil,
                     event_publisher: nil, module_execution: nil)
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
        block_configuration_errors(now)
        due_by_project = managed.to_h do |entry|
          store = begin
            store_for(entry)
          rescue StandardError => error
            recovery_state_unavailable(entry, error)
            nil
          end
          next [ entry.fetch("name"), [] ] unless store

          unless recover_occurrences(store, entry, now)
            next [ entry.fetch("name"), [] ]
          end
          discovery = if entry.dig("_refactor_patrol_cfg", "refactor_patrol", "enabled") == true
            store.claimable_jobs(now: now)
          else
            []
          end
          work = discovery.map { |job| { aggregate: job, phase: :discovery } } +
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
          work.filter_map do |item|
            aggregate = item.fetch(:aggregate)
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
        store = store_for(entry)
        aggregate = store.read_job(candidate.fetch(:job_id))
        cfg = begin
          @config_loader.call(entry.fetch("path"))
        rescue StandardError => e
          evidence = {
            "name" => entry["name"].to_s,
            "path" => File.expand_path(entry.fetch("path")),
            "error" => "#{e.class}: #{e.message}"
          }
          block(
            entry, aggregate,
            reason: "project_config_unavailable",
            evidence: evidence,
            now: now,
            phase: phase
          )
          raise ReservationBlocked.new("project_config_unavailable", evidence)
        end
        enabled = cfg.dig("daemon", "enabled") == true &&
                  (phase == :action || cfg.dig("refactor_patrol", "enabled") == true)
        unless enabled
          raise ReservationBlocked.new("architecture_patrol_disabled")
        end

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
            migration_epoch: migration.fetch("epoch")
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
        branch = cfg["default_branch"].to_s
        raise ReservationBlocked.new("missing_default_branch") if branch.empty?
        if @owner_process_start_time.to_s.empty?
          evidence = { "owner_pid" => @owner_pid }
          block(
            entry, aggregate, reason: "process_identity_unavailable",
            evidence: evidence, now: now, phase: phase
          )
          raise ReservationBlocked.new("process_identity_unavailable", evidence)
        end

        snapshot = @checkout_guard_factory.call(entry.fetch("path"), branch)
                                          .validate_and_snapshot!(
                                            merge_sha: aggregate.dig("source", "merge_sha"),
                                            analysis_sha: aggregate["analysis_sha"]
                                          )
        analysis_sha = snapshot.fetch("analysis_sha")
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
        return dispatch if dispatch.dig(:dispatch_token, :phase) == :action

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
          backoff_sec: discovery_backoff_sec(envelope, now)
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
        @job_store_factory.call(entry.fetch("path"))
      end

      def result_path_for(entry, job_id, phase)
        File.join(
          entry.fetch("path"), ".hive-state", "refactor_patrol", "v2", "results",
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
            entry.fetch("path"), ".hive-state", "refactor_patrol", "v2", "manifests",
            "#{aggregate.fetch('job_id')}.json"
          )
        }
      end

      def block(entry, aggregate, reason:, evidence:, now:, phase: :discovery)
        unless @dry_run
          store = store_for(entry)
          block_through_gateway!(
            entry, store, aggregate, phase: phase,
            reason: reason, evidence: evidence, now: now,
            backoff_sec: RETRY_BACKOFF_SEC
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
        unless manifest["job_id"] == aggregate.fetch("job_id") && source == aggregate.fetch("source")
          raise Hive::RefactorPatrol::JobStore::InconsistentRecord,
                "published manifest does not match authoritative job"
        end
      end

      def entry_for_token(token)
        registration = token.fetch(:registration)
        entry = Array(@registry.call).find { |candidate| candidate.fetch("name") == registration }
        raise Hive::RefactorPatrol::JobStore::RecordNotFound, "claimed refactor patrol job registration not found" unless entry

        aggregate = store_for(entry).read_job(token.fetch(:job_id))
        unless aggregate.dig("source", "registration") == registration
          raise Hive::RefactorPatrol::JobStore::InconsistentRecord,
                "claimed refactor patrol job registration does not match its token"
        end
        entry
      end

      def completion_failure_reason(exit_code, envelope)
        return "child_failed_or_signaled" unless exit_code == 0
        return "missing_envelope" if envelope.nil?

        "malformed_envelope"
      end

      def discovery_backoff_sec(envelope, now)
        errors = Array(envelope["review_errors"])
        reasons = errors.filter_map do |error|
          error.dig("details", "resource_exhaustion", "reason") if error.is_a?(Hash)
        end
        daily = %w[
          daily_agent_spawn_limit daily_architecture_unmetered_spawn_limit
          daily_architecture_review_spawn_limit
          daily_token_headroom daily_token_limit
        ]
        return RETRY_BACKOFF_SEC unless errors.any? && reasons.size == errors.size && (reasons - daily).empty?

        next_day = Time.utc(now.utc.year, now.utc.month, now.utc.day) + 86_400
        [ (next_day - now).ceil, RETRY_BACKOFF_SEC ].max
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
        status = if valid
          aggregate.fetch("complete") ? :closed : :action_pending
        else
          aggregate = block_through_gateway!(
            entry, store, aggregate, phase: :action,
            reason: action_completion_failure_reason(exit_code, envelope),
            evidence: {},
            now: now,
            backoff_sec: RETRY_BACKOFF_SEC
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
          accepted_count: use_envelope ? Array(envelope["accepted"]).size : Array(dispositions && dispositions["accepted"]).size,
          flagged_count: use_envelope ? Array(envelope["flagged"]).size : Array(dispositions && dispositions["flagged"]).size,
          suppressed_count: use_envelope ? Array(envelope["suppressed"]).size : Array(dispositions && dispositions["suppressed"]).size,
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
