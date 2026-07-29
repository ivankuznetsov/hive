require "json"
require "open3"
require "shellwords"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/modules/event_publisher"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/patrol/state_store"

module Hive
  module Daemon
    # Slow-cadence collaborator that decides which registered projects
    # should receive one `hive patrol PROJECT --json` scan cycle. It only
    # returns dispatch hashes; Dispatcher still owns daemon.enabled,
    # legacy-layout, dry-run, and concurrency gates before spawning.
    class PatrolScheduler
      PATROL_STAGE = "patrol".freeze
      PATROL_SLUG = "patrol".freeze
      MODULE_SCHEDULE = "*/10 * * * *".freeze
      FAILURE_BACKOFF_SCHEDULE = [ 60, 300, 900 ].freeze
      RECOVERY_BACKOFF_SCHEDULE = [ 60, 300, 900 ].freeze
      RECOVERY_ERROR_LIMIT = 512

      class GitHelper
        def default_branch(project_root, cfg:)
          cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        end

        def rev_parse(project_root, ref)
          out, err, status = Open3.capture3("git", "-C", project_root, "rev-parse", ref)
          raise Hive::GitError, "git rev-parse #{ref} failed: #{err.strip.empty? ? out : err}" unless status.success?

          out.strip
        end
      end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     git: GitHelper.new, migration_authority: :legacy,
                     migration_ownership: nil, migration_snapshot: nil,
                     evidence_store_factory: nil, event_publisher: nil,
                     state_store_factory: nil)
        @registry = registry
        @config_loader = config_loader
        @git = git
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
        @state_store_factory = state_store_factory || lambda do |entry|
          Hive::Patrol::StateStore.new(entry.fetch("path"))
        end
        @pending = {}
        @failures = {}
        @recovery_failures = {}
        @next_check_at = {}
        @events = []
      end

      def tick(now: Time.now)
        candidates(now: now).filter_map { |candidate| reserve(candidate, now: now) }
      end

      # Side-effect-free with respect to dispatch ownership: callers may
      # compare ordinary and architecture work without consuming a patrol
      # turn (`@pending` is touched only by reserve/complete/cancel).
      # Due-check throttles are NOT deferred, though: every project this
      # scan evaluates commits its `@next_check_at` window at evaluation
      # time — disabled, not-yet-due, and due candidates alike — and
      # `reserve` never touches the throttle. So a due candidate the
      # arbiter passes over is re-evaluated only after a full poll window,
      # and a second `candidates` call within one tick yields no work.
      def candidates(now: Time.now)
        @events.clear
        dispatches = []
        @registry.call.each do |entry|
          project = entry.fetch("name")
          recovery_occurrence = recover_projections(entry, now: now)
          next if recovery_occurrence == false
          next unless @migration_ownership.call(entry, "patrol", @migration_authority)
          next if pending?(project)
          if recovery_occurrence
            dispatches << dispatch_for(entry).merge(
              recovery_occurrence_id:
                recovery_occurrence.fetch("occurrence_id")
            )
            next
          end
          next if backed_off?(project, now)
          # Slow patrol cadence (U2): once a project has been evaluated,
          # don't re-run its per-project git/config checks until
          # poll_interval_sec has elapsed. Without this the `new_commits`
          # trigger shells out to `git rev-parse` on every daemon tick
          # (~30s) instead of the configured patrol interval. A project
          # with an outstanding failure is exempt so its backoff schedule
          # governs the retry rather than the slow poll.
          next if throttled?(project, now)

          cfg = @config_loader.call(entry.fetch("path"))
          patrol = cfg.fetch("patrol", {})
          # Throttle every project we evaluate, including opted-out ones:
          # each branch below commits `@next_check_at` once the project's
          # config has been loaded. Otherwise a disabled project would
          # reload its full config on every ~30s tick just to rediscover
          # patrol.enabled: false. A project that flips to enabled
          # mid-interval is picked up on its next poll window.
          unless patrol["enabled"] == true
            finalize_negative(
              entry, patrol: patrol, rationale: "disabled", now: now
            )
            @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
            next
          end
          unless due?(entry, cfg, patrol, now)
            finalize_negative(
              entry, patrol: patrol, rationale: "not_due", now: now
            )
            @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
            next
          end

          @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
          dispatches << dispatch_for(entry, patrol: patrol)
        rescue Hive::ConfigError, Hive::GitError, KeyError
          next
        end
        dispatches
      end

      def drain_events
        drained = @events.dup
        @events.clear
        drained
      end

      def reserve(candidate, now: Time.now)
        project = candidate.fetch(:project)
        entry = candidate.fetch(:migration_entry)
        return nil unless @migration_ownership.call(entry, "patrol", @migration_authority)
        return nil if pending?(project)

        snapshot = @migration_snapshot.call(entry, "patrol")
        return nil unless reservation_owner?(snapshot)

        state = state_store(entry)
        capture = if candidate[:recovery_occurrence_id]
          state.occurrence_capture(candidate.fetch(:recovery_occurrence_id))
        else
          interval = @config_loader.call(entry.fetch("path"))
                                   .dig("patrol", "poll_interval_sec") || 600
          base_id = schedule_reservation_id(entry, now, interval)
          state.reserve_attempt_occurrence!(base_id, now: now) do |generation|
            capture_reservation(
              entry, snapshot, now,
              poll_interval_sec: interval,
              attempt_generation: generation
            )
          end
        end
        return nil unless capture &&
                          capture.owner == snapshot.fetch("owner") &&
                          capture.owner_epoch == snapshot.fetch("epoch")

        if candidate[:recovery_occurrence_id]
          state.reserve_occurrence!(capture, now: now)
        end
        @pending[project] = {
          started_at: now,
          entry: entry,
          occurrence_id: capture.occurrence_id
        }
        public_dispatch(candidate, capture: capture)
      rescue StandardError
        @pending.delete(project)
        raise
      end

      def complete(project:, exit_code:, envelope: nil, now: Time.now)
        pending = @pending.fetch(project, nil)
        begin
          finalize_pending(
            pending, exit_code: exit_code, envelope: envelope, now: now
          ) if pending
        ensure
          # The child has ended even when durable finalization fails. Keep the
          # reserved occurrence as the recovery authority, but never let this
          # process-local dispatch marker hide it from the next scheduler scan.
          @pending.delete(project)
        end
        if exit_code == Hive::ExitCodes::SUCCESS
          @failures.delete(project)
        else
          count = @failures.dig(project, :count).to_i + 1
          interval = FAILURE_BACKOFF_SCHEDULE[
            [ count - 1, FAILURE_BACKOFF_SCHEDULE.size - 1 ].min
          ]
          @failures[project] = { count: count, next_eligible_at: now + interval }
        end
      end

      # Legacy `tick`-path escape hatch. In that mode (no arbiter) `tick`
      # reserves — marking `@pending` — before the Dispatcher applies its
      # gates (daemon-disabled, legacy layout, concurrency cap), so a
      # gated dispatch must release the marker here or the project would
      # stay pending until daemon restart: the gated paths never reach
      # `complete`, the only other thing that clears `@pending`. In
      # always-on arbiter mode the Dispatcher calls `reserve` only AFTER
      # those gates pass, so nothing is pending when they fire and its
      # pre-reserve `cancel` calls are no-ops there. No failure is
      # recorded — the scan never ran, so there is nothing to back off
      # from. Genuine spawn *errors* go through `complete` with a
      # non-zero exit instead.
      def cancel(project:)
        @pending.delete(project)
      end

      def pending?(project)
        @pending.key?(project)
      end

      private

      def backed_off?(project, now)
        deadline = @failures.dig(project, :next_eligible_at)
        deadline && now < deadline
      end

      def throttled?(project, now)
        return false if @failures.key?(project)

        deadline = @next_check_at[project]
        deadline && now < deadline
      end

      def due?(entry, cfg, patrol, now)
        state = read_state(entry.fetch("path"))
        case patrol.fetch("trigger", "continuous")
        when "timer"
          timer_due?(state, patrol, now)
        when "continuous"
          default_branch_changed?(entry, cfg, state) || timer_due?(state, patrol, now)
        else
          default_branch_changed?(entry, cfg, state)
        end
      end

      def timer_due?(state, patrol, now)
        last = parse_time(state["last_run_at"])
        last.nil? || (now - last) >= patrol.fetch("poll_interval_sec", 600)
      end

      def default_branch_changed?(entry, cfg, state)
        branch = @git.default_branch(entry.fetch("path"), cfg: cfg)
        current = @git.rev_parse(entry.fetch("path"), branch)
        current != state["last_scanned_sha"]
      end

      def read_state(project_root)
        path = File.join(project_root, ".hive-state", "patrol", "state.json")
        return {} unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      def parse_time(value)
        value && Time.parse(value)
      rescue ArgumentError
        nil
      end

      def dispatch_for(entry, patrol: {})
        project = entry.fetch("name")
        {
          project: project,
          slug: PATROL_SLUG,
          stage: PATROL_STAGE,
          command: "hive patrol #{Shellwords.escape(project)} --json",
          patrol_kind: :ordinary,
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: entry["hive_state_path"],
          migration_entry: entry
        }
      end

      def public_dispatch(candidate, capture:)
        dispatch = candidate.reject { |key, _value| key == :patrol_kind }
        dispatch.merge(
          command: "#{dispatch.fetch(:command)} --occurrence-id #{capture.occurrence_id}"
        )
      end

      def reservation_owner?(snapshot)
        snapshot.is_a?(Hash) &&
          snapshot["owner"] == @migration_authority.to_s &&
          snapshot["admission"] == true &&
          snapshot["epoch"].is_a?(Integer) &&
          snapshot["epoch"].positive?
      end

      def capture_reservation(entry, snapshot, now, poll_interval_sec:,
                              rationale: "due", attempt_generation: 1)
        occurred = schedule_window(now, poll_interval_sec)
        occurred_at = occurred.iso8601(6)
        reservation_id = schedule_reservation_id(
          entry, now, poll_interval_sec
        )
        trigger = {
          "kind" => "schedule",
          "id" => "#{reservation_id}:attempt:#{attempt_generation}",
          "schedule" => MODULE_SCHEDULE,
          "occurred_at" => occurred_at
        }
        Hive::Modules::Migration::PatrolCapture.build(
          module_name: "patrol",
          project: {
            "project_id" => entry.fetch("project_id"),
            "name" => entry.fetch("name"),
            "repository" => entry["repository"]
          },
          trigger: trigger,
          reservation: {
            "kind" => "ordinary",
            "id" => reservation_id,
            "attempt_generation" => attempt_generation
          },
          owner: snapshot.fetch("owner"),
          owner_epoch: snapshot.fetch("epoch"),
          decision_class: rationale,
          decision: {
            "rationale" => rationale,
            "reservation_id" => reservation_id,
            "attempt_generation" => attempt_generation
          },
          occurred_at: occurred,
          recorded_at: occurred
        )
      end

      def state_store(entry)
        @state_store_factory.call(entry)
      end

      def schedule_reservation_id(entry, now, poll_interval_sec)
        occurred = schedule_window(now, poll_interval_sec)
        [
          "ordinary", entry.fetch("project_id"),
          occurred.iso8601(6)
        ].join(":")
      end

      def recover_projections(entry, now:)
        project = entry.fetch("name")
        deadline = @recovery_failures.dig(project, :next_eligible_at)
        return false if deadline && now < deadline

        store = state_store(entry)
        projection_ids = []
        oldest_reserved = nil
        store.each_occurrence do |record|
          if record.fetch("phase") == "reserved" &&
             (!oldest_reserved ||
              record.fetch("created_at") <
                oldest_reserved.fetch("created_at"))
            oldest_reserved = record
          end
          if record.fetch("outbox").any? do |outbox_entry|
            outbox_entry.fetch("acknowledged") == false
          end
            projection_ids << record.fetch("occurrence_id")
          end
        end
        if projection_ids.empty?
          @recovery_failures.delete(project)
          return oldest_reserved
        end

        evidence = @evidence_store_factory.call(entry)
        occurrence_id = nil
        projection_ids.each do |pending_id|
          occurrence_id = pending_id
          store.drain_occurrence_outbox!(
            occurrence_id,
            evidence_store: evidence,
            event_publisher: @event_publisher,
            project_entry: entry
          )
        end
        @recovery_failures.delete(project)
        oldest_reserved
      rescue StandardError => e
        count = @recovery_failures.dig(project, :count).to_i + 1
        interval = RECOVERY_BACKOFF_SCHEDULE[
          [ count - 1, RECOVERY_BACKOFF_SCHEDULE.size - 1 ].min
        ]
        retry_at = now + interval
        @recovery_failures[project] = {
          count: count,
          next_eligible_at: retry_at
        }
        @events << {
          status: :blocked,
          project: project,
          occurrence_id: occurrence_id,
          recovery: "occurrence_outbox_projection",
          blocker: "recovery_failed",
          error_class: e.class.name,
          error: e.message.to_s.byteslice(0, RECOVERY_ERROR_LIMIT),
          retry_count: count,
          retry_in_sec: interval,
          retry_at: retry_at.utc.iso8601
        }
        false
      end

      def finalize_negative(entry, patrol:, rationale:, now:)
        snapshot = @migration_snapshot.call(entry, "patrol")
        return unless reservation_owner?(snapshot)

        store = state_store(entry)
        capture = capture_reservation(
          entry, snapshot, now,
          poll_interval_sec: patrol.fetch("poll_interval_sec", 600).to_i,
          rationale: rationale
        )
        store.reserve_occurrence!(capture, now: now)
        existing = store.occurrence(capture.occurrence_id)
        if existing.fetch("phase") == "finalized"
          store.drain_occurrence_outbox!(
            capture.occurrence_id,
            evidence_store: @evidence_store_factory.call(entry),
            event_publisher: @event_publisher,
            project_entry: entry
          )
          return
        end
        event = @event_publisher.prepare_patrol_finalized(
          entry, capture, schedule: MODULE_SCHEDULE
        )
        store.finalize_occurrence!(
          capture: capture,
          event: event,
          evidence_store: @evidence_store_factory.call(entry),
          event_publisher: @event_publisher,
          project_entry: entry,
          now: now
        )
      end

      def finalize_pending(pending, exit_code:, envelope:, now:)
        entry = pending.fetch(:entry)
        store = state_store(entry)
        provisional = store.occurrence_capture(
          pending.fetch(:occurrence_id)
        )
        raise Hive::ConfigError, "patrol pending occurrence is unavailable" unless provisional
        existing = store.occurrence(provisional.occurrence_id)
        if existing.fetch("phase") == "finalized"
          store.drain_occurrence_outbox!(
            provisional.occurrence_id,
            evidence_store: @evidence_store_factory.call(entry),
            event_publisher: @event_publisher,
            project_entry: entry
          )
          return
        end

        success = exit_code == Hive::ExitCodes::SUCCESS &&
                  envelope.is_a?(Hash) && envelope["ok"] == true
        decision = {
          "rationale" => success ? "completed" : "failed",
          "exit_code" => exit_code.nil? ? nil : Integer(exit_code),
          "ok" => success
        }
        if envelope.is_a?(Hash)
          %w[
            features_mapped features_reviewed review_complete findings
            fixes_attempted prs_opened last_scanned_sha
          ].each do |key|
            decision[key] = envelope[key] if envelope.key?(key)
          end
        end
        capture = Hive::Modules::Migration::PatrolCapture.build(
          module_name: "patrol",
          project: provisional.project,
          trigger: provisional.trigger,
          reservation: provisional.reservation,
          owner: provisional.owner,
          owner_epoch: provisional.owner_epoch,
          decision_class: success ? "completed" : "failed",
          decision: decision,
          effect_ids: store.terminal_effect_receipt_ids(
            provisional.occurrence_id
          ),
          occurred_at: provisional.occurred_at,
          recorded_at: now
        )
        event = @event_publisher.prepare_patrol_finalized(
          entry, capture, schedule: MODULE_SCHEDULE
        )
        store.finalize_occurrence!(
          capture: capture,
          event: event,
          evidence_store: @evidence_store_factory.call(entry),
          event_publisher: @event_publisher,
          project_entry: entry,
          now: now
        )
      rescue ArgumentError, TypeError
        raise Hive::ConfigError,
              "patrol completion outcome is malformed"
      end

      def schedule_window(now, interval)
        seconds = [ Integer(interval), 1 ].max
        Time.at(now.to_i - (now.to_i % seconds)).utc
      rescue ArgumentError, TypeError
        raise Hive::ConfigError, "patrol poll interval is malformed"
      end
    end
  end
end
