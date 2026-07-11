require "json"
require "json_schemer"
require "pathname"
require "shellwords"
require "time"
require "hive/config"
require "hive/gh"
require "hive/lock"
require "hive/process_kill"
require "hive/refactor_patrol/checkout_guard"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/pr_manifest"

module Hive
  module Daemon
    # Exposes durable merged-PR architecture work to PatrolArbiter and owns
    # the discovery claim/fence lifecycle around its child process.
    class RefactorPatrolScheduler
      PATROL_STAGE = "refactor-patrol".freeze
      PATROL_SLUG_PREFIX = "refactor-patrol".freeze
      RETRY_BACKOFF_SEC = 60

      class ReservationBlocked < StandardError
        attr_reader :reason, :evidence

        def initialize(reason, evidence = {})
          @reason = reason.to_s
          @evidence = evidence
          super(@reason)
        end
      end

      class ProcessGroupResolver
        def call(attempt)
          return resolve_unattached_owner(attempt) if attempt["pid"].nil?

          pid = Integer(attempt.fetch("pid"))
          pgid = Integer(attempt.fetch("pgid"))
          recorded_start = attempt.fetch("process_start_time").to_s
          return :unresolved unless Hive::ProcessKill.valid_target_pid?(pid)
          return :unresolved if pgid <= 1 || recorded_start.empty?
          return :resolved unless Hive::ProcessKill.pid_alive?(pid)

          live_start = Hive::ProcessKill.process_start_time(pid)
          return :unresolved if live_start.to_s.empty?
          return :resolved unless live_start.to_s == recorded_start

          live_pgid = Process.getpgid(pid)
          return :unresolved unless live_pgid == pgid

          result = Hive::ProcessKill.terminate_process_group(
            pid, recorded_start_time: recorded_start
          )
          result.killed || result.skipped_reason == "not_alive" ? :resolved : :unresolved
        rescue KeyError, ArgumentError, TypeError, Errno::EPERM
          :unresolved
        rescue Errno::ESRCH
          :resolved
        end

        private

        def resolve_unattached_owner(attempt)
          pid = Integer(attempt.fetch("owner_pid"))
          recorded_start = attempt.fetch("owner_process_start_time").to_s
          return :unresolved unless Hive::ProcessKill.valid_target_pid?(pid)
          return :unresolved if recorded_start.empty?
          return :resolved unless Hive::ProcessKill.pid_alive?(pid)

          live_start = Hive::ProcessKill.process_start_time(pid)
          return :unresolved if live_start.to_s.empty?

          live_start.to_s == recorded_start ? :unresolved : :resolved
        rescue KeyError, ArgumentError, TypeError
          :unresolved
        end
      end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     job_store_factory: ->(path) { Hive::RefactorPatrol::JobStore.new(path) },
                     checkout_guard_factory: nil, repository_resolver: nil,
                     owner: nil, claim_resolver: ProcessGroupResolver.new,
                     lease_sec: 7200, dry_run: false)
        @registry = registry
        @config_loader = config_loader
        @job_store_factory = job_store_factory
        @checkout_guard_factory = checkout_guard_factory || lambda do |path, branch|
          Hive::RefactorPatrol::CheckoutGuard.new(path, default_branch: branch)
        end
        @repository_resolver = repository_resolver || lambda do |entry, cfg|
          Hive::Gh.repo_name_with_owner(entry.fetch("path"), cfg: cfg)
        end
        @owner_pid = Process.pid
        @owner_process_start_time = Hive::Lock.process_start_time(Process.pid)
        @owner = owner || "daemon-#{Process.pid}-#{@owner_process_start_time || 'unverified'}"
        @claim_resolver = claim_resolver
        @lease_sec = lease_sec.to_i
        @dry_run = dry_run
        @repository_cache = {}
        @events = []
        @schemer = JSONSchemer.schema(
          Pathname.new(Hive::Schemas.schema_path("hive-refactor-patrol", version: 2))
        )
      end

      def candidates(now: Time.now)
        @events.clear
        managed = managed_entries
        prune_repository_cache(managed)
        due_by_project = managed.to_h do |entry|
          store = store_for(entry)
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

        active = managed.select { |entry| due_by_project.fetch(entry.fetch("name")).any? }
        identity_entries = managed.select do |entry|
          entry.dig("_refactor_patrol_cfg", "refactor_patrol", "enabled") == true ||
            due_by_project.fetch(entry.fetch("name")).any?
        end
        duplicates, unresolved = duplicate_repositories(identity_entries)
        active.flat_map do |entry|
          project = entry.fetch("name")
          work = due_by_project.fetch(project)
          if unresolved.any?
            evidence = { "unresolved_registrations" => unresolved }
            work.each do |item|
              block(
                entry, item.fetch(:aggregate), reason: "repository_identity_unresolved",
                evidence: evidence, now: now
              )
            end
            next []
          end
          duplicate = duplicates[project]
          if duplicate
            work.each do |item|
              block(
                entry, item.fetch(:aggregate), reason: "duplicate_repository_registration",
                evidence: duplicate, now: now
              )
            end
            next []
          end

          work.map { |item| candidate_for(entry, item.fetch(:aggregate), phase: item.fetch(:phase)) }
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
        cfg = @config_loader.call(entry.fetch("path"))
        phase = candidate.fetch(:action_phase, :discovery).to_sym
        enabled = cfg.dig("daemon", "enabled") == true &&
                  (phase == :action || cfg.dig("refactor_patrol", "enabled") == true)
        unless enabled
          raise ReservationBlocked.new("architecture_patrol_disabled")
        end

        store = store_for(entry)
        aggregate = store.read_job(candidate.fetch(:job_id))
        manifest_path = candidate.fetch(:manifest_path)
        assert_manifest_matches!(manifest_path, aggregate)
        if phase == :action
          token = {
            kind: :architecture_patrol,
            phase: :action,
            job_id: aggregate.fetch("job_id"),
            registration: entry.fetch("name")
          }
          return candidate.merge(
            slug: "#{PATROL_SLUG_PREFIX}-#{aggregate.fetch('job_id')}-actions",
            stage: PATROL_STAGE,
            command: "hive refactor-patrol #{Shellwords.escape(entry.fetch('name'))} " \
                     "--job-manifest #{Shellwords.escape(manifest_path)} --actions --json",
            state_file_mtime: nil,
            state_file_path: nil,
            hive_state_path: entry["hive_state_path"],
            dispatch_token: token
          )
        end
        branch = cfg["default_branch"].to_s
        raise ReservationBlocked.new("missing_default_branch") if branch.empty?

        snapshot = @checkout_guard_factory.call(entry.fetch("path"), branch)
                                          .validate_and_snapshot!(merge_sha: aggregate.dig("source", "merge_sha"))
        analysis_sha = snapshot.fetch("analysis_sha")
        token = if @dry_run
          { job_id: aggregate.fetch("job_id"), owner: @owner, generation: 0, dry_run: true }
        else
          store.claim_discovery!(
            aggregate.fetch("job_id"), owner: @owner, analysis_sha: analysis_sha,
            now: now, lease_sec: @lease_sec, claim_resolver: @claim_resolver,
            owner_pid: @owner_pid, owner_process_start_time: @owner_process_start_time
          )
        end
        raise ReservationBlocked.new("claim_unavailable") unless token

        candidate.merge(
          slug: "#{PATROL_SLUG_PREFIX}-#{aggregate.fetch('job_id')}",
          stage: PATROL_STAGE,
          command: "hive refactor-patrol #{Shellwords.escape(entry.fetch('name'))} " \
                   "--job-manifest #{Shellwords.escape(manifest_path)} --json",
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: entry["hive_state_path"],
          dispatch_token: token.merge(
            kind: :architecture_patrol, phase: :discovery,
            registration: entry.fetch("name")
          )
        )
      rescue ReservationBlocked
        raise
      rescue Hive::GitError, Hive::RefactorPatrol::JobStore::Error, Hive::RefactorPatrol::PrManifest::Invalid,
             JSON::ParserError,
             SystemCallError, IOError, KeyError => e
        reason = e.is_a?(Hive::GitError) ? "checkout_guard" : "reservation_error"
        block(entry, aggregate || { "job_id" => candidate.fetch(:job_id), "source" => candidate.fetch(:source) },
              reason: reason, evidence: { "error" => "#{e.class}: #{e.message}" }, now: now)
        raise ReservationBlocked.new(reason, "error" => "#{e.class}: #{e.message}")
      end

      def spawned(dispatch, pid:, process_start_time:, pgid:, now: Time.now)
        return dispatch if @dry_run
        return dispatch if dispatch.dig(:dispatch_token, :phase) == :action

        store_for(dispatch.fetch(:entry)).attach_discovery_process!(
          dispatch.fetch(:dispatch_token), pid: pid,
          process_start_time: process_start_time, pgid: pgid, now: now
        )
      end

      def cancel(dispatch, reason:, now: Time.now)
        token = dispatch[:dispatch_token]
        return unless token
        return dispatch if @dry_run || token[:dry_run]
        return dispatch if token[:phase] == :action

        store_for(dispatch.fetch(:entry)).release_discovery!(
          token, reason: reason, now: now, backoff_sec: RETRY_BACKOFF_SEC
        )
      rescue Hive::RefactorPatrol::JobStore::StaleClaim
        nil
      end

      def complete(dispatch_token:, exit_code:, envelope:, now: Time.now)
        return completion_result(:dry_run, dispatch_token, envelope) if @dry_run || dispatch_token[:dry_run]
        return complete_action(dispatch_token, exit_code, envelope) if dispatch_token[:phase] == :action

        entry = entry_for_token(dispatch_token)
        store = store_for(entry)
        aggregate = store.read_job(dispatch_token.fetch(:job_id))
        unless exit_code == 0 && envelope.is_a?(Hash) && @schemer.valid?(envelope)
          aggregate = store.release_discovery!(
            dispatch_token, reason: completion_failure_reason(exit_code, envelope),
            now: now, backoff_sec: RETRY_BACKOFF_SEC
          )
          return completion_result(:retry, dispatch_token, envelope, aggregate: aggregate)
        end

        aggregate = store.checkpoint_discovery!(dispatch_token, envelope: envelope, now: now)
        completion_result(
          aggregate.fetch("complete") ? :closed : :classified,
          dispatch_token, envelope, aggregate: aggregate
        )
      rescue Hive::RefactorPatrol::JobStore::StaleClaim
        completion_result(:stale, dispatch_token, envelope, aggregate: aggregate)
      rescue Hive::RefactorPatrol::JobStore::Error, KeyError
        begin
          store&.release_discovery!(
            dispatch_token, reason: "mismatched_completion", now: now,
            backoff_sec: RETRY_BACKOFF_SEC
          )
        rescue Hive::RefactorPatrol::JobStore::Error
          nil
        end
        completion_result(:retry, dispatch_token, envelope, aggregate: aggregate)
      end

      private

      def managed_entries
        Array(@registry.call).filter_map do |entry|
          cfg = @config_loader.call(entry.fetch("path"))
          next unless cfg.dig("daemon", "enabled") == true

          entry.merge("_refactor_patrol_cfg" => cfg)
        rescue Hive::ConfigError, KeyError
          nil
        end
      end

      def duplicate_repositories(entries)
        resolved = {}
        unresolved = []
        entries.each do |entry|
          key = [ entry.fetch("name"), File.expand_path(entry.fetch("path")) ]
          if @repository_cache.key?(key)
            resolved[entry] = @repository_cache.fetch(key)
            next
          end
          repository = @repository_resolver.call(entry, entry.fetch("_refactor_patrol_cfg")).to_s.downcase
          raise Hive::GhError, "repository identity is empty" if repository.empty?

          resolved[entry] = @repository_cache[key] = repository
        rescue StandardError => e
          unresolved << {
            "name" => entry.fetch("name"), "path" => File.expand_path(entry.fetch("path")),
            "error" => "#{e.class}: #{e.message}"
          }
        end
        groups = resolved.keys.group_by { |entry| resolved.fetch(entry) }
        duplicates = groups.each_with_object({}) do |(repository, registrations), result|
          next unless registrations.size > 1

          evidence = {
            "repository" => repository,
            "registrations" => registrations.map do |entry|
              { "name" => entry.fetch("name"), "path" => File.expand_path(entry.fetch("path")) }
            end.sort_by { |item| [ item.fetch("name"), item.fetch("path") ] }
          }
          registrations.each { |entry| result[entry.fetch("name")] = evidence }
        end
        [ duplicates, unresolved ]
      end

      def store_for(entry)
        @job_store_factory.call(entry.fetch("path"))
      end

      def prune_repository_cache(entries)
        current = entries.to_h { |entry| [ [ entry.fetch("name"), File.expand_path(entry.fetch("path")) ], true ] }
        @repository_cache.delete_if { |key, _repository| !current.key?(key) }
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

      def block(entry, aggregate, reason:, evidence:, now:)
        unless @dry_run
          store_for(entry).block_discovery!(
          aggregate.fetch("job_id"), reason: reason, evidence: evidence,
          now: now, backoff_sec: RETRY_BACKOFF_SEC
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

      def complete_action(token, exit_code, envelope)
        entry = entry_for_token(token)
        aggregate = store_for(entry).read_job(token.fetch(:job_id))
        valid = exit_code == 0 && envelope.is_a?(Hash) && @schemer.valid?(envelope) &&
                envelope["job_id"] == aggregate.fetch("job_id") &&
                envelope["project"] == entry.fetch("name") &&
                envelope["project_root"] == entry.fetch("path") &&
                envelope["source_pr"] == aggregate.fetch("source") &&
                envelope["analysis_sha"] == aggregate.fetch("analysis_sha") &&
                envelope["complete"] == aggregate.fetch("complete")
        status = if valid
          aggregate.fetch("complete") ? :closed : :action_pending
        else
          :retry
        end
        completion_result(status, token, envelope, aggregate: aggregate)
      rescue Hive::RefactorPatrol::JobStore::Error, Hive::ConfigError, KeyError
        completion_result(:retry, token, envelope, aggregate: aggregate)
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

      def parse_time(value)
        value ? Time.iso8601(value.to_s).utc : Time.at(0).utc
      rescue ArgumentError
        Time.at(0).utc
      end
    end
  end
end
