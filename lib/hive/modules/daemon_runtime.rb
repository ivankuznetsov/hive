require "hive/attempts/configured_dispatcher"
require "json"
require "hive/atomic_file"
require "hive/config"
require "hive/module_package/managed_store"
require "hive/modules/decision_journal"
require "hive/modules/dispatcher"
require "hive/modules/event_ledger"
require "hive/modules/event_router"
require "hive/modules/event_scope"
require "hive/modules/hook_attempt"
require "hive/modules/migration/patrols"
require "hive/modules/schedule_planner"

module Hive
  module Modules
    # Daemon-owned drain for persisted module occurrences and schedules.
    # Existing commands/reconcilers only publish; this is the sole autonomous
    # hook dispatcher.
    class DaemonRuntime
      MAX_RETRIES = 2
      RETRY_DELAY_SEC = 3600
      DEFAULT_DISPATCHER_FACTORY =
        ->(**dependencies) { Dispatcher.new(**dependencies) }.freeze

      def initialize(attempt_store:, attempt_dispatcher:, registry: -> { Hive::Config.registered_projects },
                     planner: SchedulePlanner.new, migration_owner: nil,
                     dispatcher_factory: DEFAULT_DISPATCHER_FACTORY,
                     clock: -> { Time.now.utc })
        @attempt_store = attempt_store
        @attempt_dispatcher = attempt_dispatcher
        @registry = registry
        @planner = planner
        @migration_owner = migration_owner || lambda do |entry, module_name|
          Hive::Modules::Migration::Patrols.owner_for(
            entry.fetch("path"), module_name,
            hive_state_path: entry["hive_state_path"]
          )
        end
        @dispatcher_factory = dispatcher_factory
        @clock = clock
      end

      def tick(now: @clock.call)
        Array(@registry.call).map { |entry| tick_project(entry, now: now) }
      end

      private

      def tick_project(entry, now:)
        store = Hive::ModulePackage::ManagedStore.new(entry.fetch("hive_state_path"))
        selections = store.selections(include_tombstones: true)
        return result(entry, :idle, 0, 0) if selections.empty?

        runtime_root = File.join(entry.fetch("hive_state_path"), "module-runtime")
        ledger = EventLedger.new(root: runtime_root)
        journal = DecisionJournal.new(root: runtime_root)
        dispatcher = @dispatcher_factory.call(
          store: store, attempt_store: @attempt_store,
          attempt_dispatcher: @attempt_dispatcher,
          project_id: entry.fetch("project_id"), project: entry.fetch("name"),
          decision_journal: journal, clock: -> { now }
        )
        reconcile_runs(store, selections, dispatcher: dispatcher, now: now)
        promote_setup_outboxes(store, selections, ledger: ledger, entry: entry, now: now)
        installed_selections = selections.select { |selection| selection.fetch("installed") }
        return result(entry, :idle, 0, 0) if installed_selections.empty?

        schedules = dispatch_schedules(
          installed_selections, store: store, ledger: ledger,
          entry: entry, now: now
        )
        decisions = drain_events(
          installed_selections, store: store, ledger: ledger,
          dispatcher: dispatcher
        )
        result(entry, :ok, decisions, schedules)
      rescue Hive::Error, SystemCallError, IOError, JSON::ParserError => e
        result(entry, :blocked, 0, 0, reason: "#{e.class}: #{e.message}")
      end

      def drain_events(selections, store:, ledger:, dispatcher:)
        count = 0
        cursor_path = File.join(ledger.root, "daemon-event-cursor.json")
        cursor = read_event_cursor(cursor_path)
        page = ledger.events_after(cursor)
        page.events.each_with_index do |event, index|
          selections.each do |selection|
            configuration = store.configuration(
              selection.fetch("name"), selection.dig("active", "configuration_digest")
            )
            configuration.contract.fetch("hooks").each do |hook|
              next unless EventScope.matches?(event: event, selection: selection, hook: hook)

              dispatcher.dispatch(
                module_name: selection.fetch("name"), hook_id: hook.fetch("id"), event: event
              )
              count += 1
            end
          end
          write_event_cursor(cursor_path, cursor + index + 1)
        end
        count
      end

      def promote_setup_outboxes(store, selections, ledger:, entry:, now:)
        selections.each do |selection|
          store.promote_setup_outbox(selection.fetch("name")) do |intent|
            unless intent.fetch("project_id") == entry.fetch("project_id").to_s &&
                   intent.fetch("project") == entry.fetch("name").to_s
              raise Hive::ConfigError, "module setup outbox belongs to another project"
            end

            ledger.record(
              project_id: intent.fetch("project_id"),
              project: intent.fetch("project"),
              event_name: "project.registered",
              occurred_at: intent.fetch("occurred_at"),
              source: {
                "type" => "module_install",
                "id" => "#{intent.fetch('module')}:#{intent.fetch('receipt_digest')}"
              },
              idempotency_key: intent.fetch("idempotency_key"),
              payload: {
                "target_module" => intent.fetch("module"),
                "target_generation" => intent.fetch("source_commit"),
                "target_configuration_digest" => intent.fetch("configuration_digest"),
                "target_hooks" => intent.fetch("hooks"),
                "install_receipt_digest" => intent.fetch("receipt_digest")
              },
              recorded_at: now
            )
          end
        end
      end

      def dispatch_schedules(selections, store:, ledger:, entry:, now:)
        schedules = selections.flat_map do |selection|
          module_name = selection.fetch("name")
          next [] unless schedule_owner?(entry, module_name)

          configuration = store.configuration(
            module_name, selection.dig("active", "configuration_digest")
          )
          configuration.contract.fetch("hooks").flat_map do |hook|
            hook.fetch("schedules").map do |schedule|
              [ module_name, schedule, Time.iso8601(selection.fetch("high_water_at")) ]
            end
          end
        end.uniq
        schedules.count do |module_name, schedule, high_water_at|
          previous = ledger.latest_schedule(schedule, target_module: module_name)
          baseline = previous || high_water_at
          occurrence = @planner.due(schedule: schedule, after: baseline, now: now)
          next false unless occurrence

          instant = occurrence.due_at.utc.iso8601(6)
          ledger.record(
            project_id: entry.fetch("project_id"), project: entry.fetch("name"),
            event_name: "schedule", occurred_at: instant,
            source: { "type" => "daemon_schedule", "id" => module_name },
            idempotency_key: "schedule:#{module_name}:#{schedule}:#{instant}",
            payload: {
              "schedule" => schedule, "due_at" => instant,
              "missed_windows" => occurrence.missed_windows,
              "target_module" => module_name
            },
            recorded_at: now
          )
          true
        end
      end

      def schedule_owner?(entry, module_name)
        return true unless Hive::Modules::Migration::Patrols::MODULES.include?(module_name)

        @migration_owner.call(entry, module_name) == "module"
      end

      def read_event_cursor(path)
        return 0 unless File.file?(path)

        bytes = File.binread(path)
        data = JSON.parse(bytes)
        canonical = Hive::WorkflowPackage::CanonicalJSON.generate(data)
        unless bytes == canonical && data.keys.sort == %w[cursor schema_version] &&
               data["schema_version"] == 1 && data["cursor"].is_a?(Integer) &&
               data["cursor"] >= 0
          raise Hive::ConfigError, "module daemon event cursor is malformed"
        end
        data.fetch("cursor")
      end

      def write_event_cursor(path, cursor)
        Hive::AtomicFile.write(
          path,
          Hive::WorkflowPackage::CanonicalJSON.generate(
            "schema_version" => 1, "cursor" => cursor
          ),
          mode: 0o600
        )
      end

      def reconcile_runs(store, selections, dispatcher:, now:)
        selections.each do |selection|
          module_name = selection.fetch("name")
          Dir.glob(File.join(store.runtime_path(module_name), "runs", "*.json")).sort.each do |path|
            run = JSON.parse(File.binread(path))
            next unless %w[admitting running retrying].include?(run["status"])
            next if retry_deferred?(run, now)
            attempt_id = run["attempt_id"]
            next unless attempt_id
            attempt = @attempt_store.fetch(attempt_id)
            next unless attempt&.final?

            if attempt.state == "terminal" && attempt.outcome == "succeeded"
              finalize_run(path, run, status: "succeeded", attempt: attempt, now: now)
            elsif ((attempt.state == "terminal" && attempt.outcome == "failed") ||
                   attempt.state == "lost") &&
                  attempt["retry_charge"] < MAX_RETRIES
              dispatcher.retry(
                module_name: module_name, hook_attempt: hook_attempt_from(run, selection),
                previous_attempt: attempt
              )
            else
              finalize_run(path, run, status: "failed", attempt: attempt, now: now)
            end
          end
        end
      end

      def retry_deferred?(run, now)
        return false unless run["status"] == "retrying"

        updated_at = Time.iso8601(run.fetch("updated_at"))
        now < updated_at + RETRY_DELAY_SEC
      rescue ArgumentError, TypeError, KeyError
        raise Hive::ConfigError, "module retry timestamp is malformed"
      end

      def hook_attempt_from(run, selection)
        subject = run.fetch("subject")
        HookAttempt.new(
          task_id: nil, project: run.fetch("project"),
          task_slug: "module-#{subject.fetch('module')}-#{subject.fetch('hook')}-#{subject.fetch('event_id')[0, 12]}",
          intended_stage: "module-hook",
          task_locator: "module:#{subject.fetch('module')}/#{subject.fetch('hook')}",
          progress_token: subject.fetch("event_id"), task_generation: run.fetch("run_id"),
          ownership_generation: run.fetch("ownership_generation"),
          task_input_epoch: run.fetch("task_input_epoch"), subject: subject,
          argv: run.fetch("argv"), execution_snapshot: run.fetch("execution_snapshot"),
          run_id: run.fetch("run_id")
        )
      end

      def finalize_run(path, run, status:, attempt:, now:)
        run["status"] = status
        run["outcome"] = attempt.outcome || attempt.state
        run["retry"] = {
          "status" => status == "succeeded" ? "complete" : "exhausted",
          "charge" => attempt["retry_charge"], "max" => MAX_RETRIES
        }
        run["updated_at"] = now.utc.iso8601(6)
        Hive::AtomicFile.write(
          path, Hive::WorkflowPackage::CanonicalJSON.generate(run), mode: 0o600
        )
      end

      def result(entry, status, decisions, schedules, reason: nil)
        {
          project: entry.fetch("name"), status: status,
          decisions: decisions, schedules: schedules, reason: reason
        }
      end
    end
  end
end
