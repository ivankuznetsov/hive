require "digest"
require "time"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/launch_policy"
require "hive/attempts/store"
require "hive/config"
require "hive/modules/decision_journal"
require "hive/modules/dispatcher"
require "hive/modules/event_ledger"
require "hive/stringify_keys"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    class DryRun
      EVENT_NAMES = [ "schedule", *Hive::ModulePackage::Manifest::EVENT_NAMES ].freeze

      def initialize(store:, project_id:, project:, attempt_store:,
                     secret_availability: ->(name) { ENV.key?(name.to_s) },
                     capacity_probe: nil,
                     clock: -> { Time.now.utc })
        @store = store
        @project_id = project_id.to_s
        @project = project.to_s
        @clock = clock
        capacity_probe ||= capacity_probe_for(attempt_store)
        journal = DecisionJournal.new(
          root: File.join(store.hive_state_path, "module-runtime"), create_directories: false
        )
        @dispatcher = Dispatcher.new(
          store: store, attempt_store: attempt_store, attempt_dispatcher: nil,
          project_id: @project_id, project: @project, decision_journal: journal,
          secret_availability: secret_availability, capacity_probe: capacity_probe,
          clock: clock
        )
      end

      def evaluate(module_name:, hook_id: nil, event_name:, occurred_at: @clock.call,
                   schedule: nil, payload: {})
        event = event(event_name, occurred_at, schedule, payload)
        results = if hook_id
          [ @dispatcher.dispatch(module_name: module_name, hook_id: hook_id, event: event, dry_run: true) ]
        else
          selection = @store.inspect_selection(module_name, include_tombstone: true)
          raise Hive::ConfigError, "module #{module_name.inspect} is not installed and has no history" unless selection
          generation = selection["active"] || selection["previous"]
          configuration = generation && @store.configuration(module_name, generation.fetch("configuration_digest"))
          Array(configuration&.contract&.fetch("hooks", [])).map do |hook|
            @dispatcher.dispatch(
              module_name: module_name, hook_id: hook.fetch("id"), event: event, dry_run: true
            )
          end
        end
        { "event" => event, "decisions" => results.map(&:decision) }
      end

      private

      def capacity_probe_for(attempts)
        lambda do |module_name:, hook_id:, event:|
          now = @clock.call
          limits = Hive::Attempts::LaunchPolicy.limits(
            daemon: Hive::Config.load_global_daemon
          )
          task_slug = "module-#{module_name}-#{hook_id}-#{event.fetch('event_id')[0, 12]}"
          Hive::Attempts::CapacitySnapshot.build(store: attempts, now: now).at_limit?(
            project: @project, task_slug: task_slug, date: now.to_date, **limits
          )
        end
      end

      def event(name, occurred_at, schedule, payload)
        name = name.to_s
        raise Hive::ConfigError, "unsupported module dry-run event #{name.inspect}" unless EVENT_NAMES.include?(name)
        occurred = timestamp(occurred_at)
        payload = Hive::StringifyKeys.call(payload)
        if name == "schedule"
          raise Hive::ConfigError, "module dry-run schedule is required" if schedule.to_s.empty?
          payload = payload.merge("schedule" => schedule.to_s, "due_at" => occurred, "missed_windows" => 0)
        end
        identity = digest([ @project_id, name, occurred, payload ])
        {
          "schema" => EventLedger::SCHEMA, "schema_version" => EventLedger::SCHEMA_VERSION,
          "event_id" => "evt-#{identity}", "event_name" => name,
          "project_id" => @project_id, "project" => @project,
          "occurred_at" => occurred, "recorded_at" => occurred,
          "source" => { "type" => "dry_run", "id" => "preview" },
          "idempotency_key" => "dry-run:#{identity}", "payload" => payload
        }
      end

      def timestamp(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise Hive::ConfigError, "module dry-run occurrence time is malformed"
      end

      def digest(value)
        ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(value))
      end
    end
  end
end
