require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/attempts/dispatcher"
require "hive/module_package/managed_store"
require "hive/modules/decision_journal"
require "hive/modules/event_scope"
require "hive/modules/hook_attempt"
require "hive/modules/trigger_evaluator"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    ModuleDispatchResult = Data.define(:decision, :attempt_result, :event) do
      def launched? = decision && decision["outcome"] == "launch"
    end

    # Project-local hook admission coordinator. One hook lock covers enabled
    # state, binding cursor, dedupe/concurrency evidence, attempt admission,
    # and the immutable decision receipt.
    class Dispatcher
      UNSET_SELECTION = Object.new.freeze

      def initialize(store:, attempt_store:, attempt_dispatcher:, project_id:, project:,
                     evaluator: TriggerEvaluator.new, decision_journal: nil,
                     secret_availability: ->(name) { ENV.key?(name.to_s) },
                     capacity_probe: ->(**) { false },
                     clock: -> { Time.now.utc })
        @store = store
        @attempt_store = attempt_store
        @attempt_dispatcher = attempt_dispatcher
        @project_id = project_id.to_s
        @project = project.to_s
        @evaluator = evaluator
        @decision_journal = decision_journal || DecisionJournal.new(
          root: File.join(store.hive_state_path, "module-runtime")
        )
        @secret_availability = secret_availability
        @capacity_probe = capacity_probe
        @clock = clock
      end

      def dispatch(module_name:, hook_id:, event:, dry_run: false)
        assert_project!(event)
        lifecycle = dry_run ? method(:without_lifecycle_lock) : @store.method(:with_admission)
        lifecycle.call(module_name) do |admitted_selection|
          lock = dry_run ? method(:without_hook_lock) : method(:with_hook_lock)
          lock.call(module_name, hook_id) do
            context = load_context(
              module_name, hook_id, read_only: dry_run, selection: admitted_selection
            )
            evaluation = evaluate(context, event)
            if dry_run || !evaluation.launch?
              decision = dry_run ? projected_decision(context, event, evaluation) :
                persist_decision(context, event, evaluation)
              advance_cursor(context, evaluation) unless dry_run ||
                %w[activation_fenced launch_handoff_failed].include?(evaluation.reason)
              return ModuleDispatchResult.new(decision: decision, attempt_result: nil, event: event)
            end

            hook_attempt = HookAttempt.build(
              project: @project, project_id: @project_id, module_name: module_name,
              hook: context.fetch(:hook), selection: context.fetch(:selection),
              configuration: context.fetch(:configuration), event: event,
              package_root: @store.generation_path(
                module_name, context.dig(:selection, "active", "source_commit")
              )
            )
            persist_run(module_name, hook_attempt, event)
            attempt_result = @attempt_dispatcher.dispatch_module_hook(
              generation: hook_attempt, subject: hook_attempt.subject,
              argv: hook_attempt.argv, request_id: "module:#{event.fetch('event_id')}:#{hook_id}",
              provider: "module", interactive: false, now: @clock.call,
              project_root: File.dirname(@store.hive_state_path)
            )
            final_evaluation = evaluation_for_attempt(evaluation, attempt_result)
            update_run(module_name, hook_attempt, attempt_result, final_evaluation)
            decision = persist_decision(
              context, event, final_evaluation,
              attempt_id: attempt_result.attempt&.attempt_id
            )
            unless final_evaluation.reason == "launch_handoff_failed"
              advance_cursor(context, final_evaluation)
            end
            ModuleDispatchResult.new(
              decision: decision, attempt_result: attempt_result, event: event
            )
          end
        end
      end

      def dispatch_event(event, dry_run: false)
        assert_project!(event)
        selections = dry_run ? @store.inspect_selections : @store.selections
        selections.flat_map do |selection|
          active = selection.fetch("active")
          configuration = @store.configuration(
            selection.fetch("name"), active.fetch("configuration_digest")
          )
          configuration.contract.fetch("hooks").filter_map do |hook|
            next unless EventScope.matches?(event: event, selection: selection, hook: hook)

            dispatch(
              module_name: selection.fetch("name"), hook_id: hook.fetch("id"),
              event: event, dry_run: dry_run
            )
          end
        end
      end

      def retry(module_name:, hook_attempt:, previous_attempt:)
        hook_id = hook_attempt.subject.fetch("hook")
        @store.with_admission(module_name) do |selection|
          with_hook_lock(module_name, hook_id) do
            unless selection&.fetch("installed") && selection.fetch("enabled")
              close_run(module_name, hook_attempt.run_id, "retry_closed")
              return nil
            end
            charge = previous_attempt["retry_charge"] + 1
            retry_attempt = hook_attempt.retry(charge)
            result = @attempt_dispatcher.dispatch_module_hook(
              generation: retry_attempt, subject: retry_attempt.subject,
              argv: retry_attempt.argv,
              request_id: "module-retry:#{retry_attempt.subject.fetch('event_id')}:#{hook_id}:#{charge}",
              provider: "module", interactive: false,
              predecessor_attempt_id: previous_attempt.attempt_id,
              retry_charge: charge, now: @clock.call,
              project_root: File.dirname(@store.hive_state_path)
            )
            update_run(module_name, retry_attempt, result, nil)
            result
          end
        end
      end

      private

      def load_context(module_name, hook_id, read_only: false, selection: UNSET_SELECTION)
        selection = if selection.equal?(UNSET_SELECTION) && read_only
          @store.inspect_selection(module_name, include_tombstone: true)
        elsif selection.equal?(UNSET_SELECTION)
          @store.selected(module_name, include_tombstone: true)
        else
          selection
        end
        return { module_name: module_name.to_s, hook_id: hook_id.to_s, selection: nil } unless selection
        active = selection["active"]
        configuration = active && @store.configuration(module_name, active.fetch("configuration_digest"))
        hook = configuration&.contract&.fetch("hooks", [])&.find { |item| item.fetch("id") == hook_id.to_s }
        hooks = read_hooks(module_name)
        hook_state = hooks.dig("hooks", hook_id.to_s)
        {
          module_name: module_name.to_s, hook_id: hook_id.to_s,
          selection: selection, configuration: configuration, hook: hook,
          hook_state: hook_state, hooks: hooks,
          activation_fenced: File.exist?(activation_barrier_path(module_name))
        }
      end

      def evaluate(context, event)
        selection = context[:selection]
        unless selection && context[:configuration] && context[:hook]
          return @evaluator.evaluate(
            selection: selection, configuration: NullConfiguration.new,
            hook: null_hook(context.fetch(:hook_id)), hook_state: nil, event: event
          )
        end
        duplicate = @decision_journal.admitted?(
          module_name: context.fetch(:module_name), hook_id: context.fetch(:hook_id),
          event_id: event.fetch("event_id")
        )
        concurrency_blocked = live_for_hook?(context) && context.fetch(:hook).fetch("concurrency") != "allow"
        capacity_blocked = @capacity_probe.call(
          module_name: context.fetch(:module_name),
          hook_id: context.fetch(:hook_id),
          event: event
        ) == true
        availability = required_secret_bindings(context.fetch(:configuration)).to_h do |binding|
          [ binding, @secret_availability.call(binding) == true ]
        end
        @evaluator.evaluate(
          selection: selection, configuration: context.fetch(:configuration),
          hook: context.fetch(:hook), hook_state: context[:hook_state], event: event,
          activation_fenced: context.fetch(:activation_fenced), duplicate: duplicate,
          concurrency_blocked: concurrency_blocked, capacity_blocked: capacity_blocked,
          secret_availability: availability
        )
      end

      def evaluation_for_attempt(evaluation, attempt_result)
        case attempt_result.status
        when :accepted
          evaluation
        when :existing_live
          evaluation.with(outcome: "skip", reason: "duplicate")
        when :terminal_replay
          evaluation.with(outcome: "skip", reason: "terminal_replay")
        else
          reason = case attempt_result.reason
          when "capacity" then "capacity_blocked"
          when "launch_handoff_failed" then "launch_handoff_failed"
          else "concurrency_blocked"
          end
          evaluation.with(outcome: "skip", reason: reason)
        end
      end

      def persist_decision(context, event, evaluation, attempt_id: nil)
        @decision_journal.append(
          decision_attributes(context, event, evaluation).merge(
            "attempt_id" => attempt_id, "evaluated_at" => @clock.call
          )
        )
      end

      def projected_decision(context, event, evaluation)
        decision_attributes(context, event, evaluation).merge(
          "schema" => DecisionJournal::SCHEMA,
          "schema_version" => DecisionJournal::SCHEMA_VERSION,
          "decision_id" => nil, "evaluated_at" => @clock.call.utc.iso8601(6),
          "attempt_id" => nil
        )
      end

      def decision_attributes(context, event, evaluation)
        selection = context[:selection]
        active = selection && selection["active"]
        configuration = context[:configuration]
        {
          "project_id" => @project_id, "project" => @project,
          "module" => context.fetch(:module_name), "hook" => context.fetch(:hook_id),
          "event_id" => event.fetch("event_id"), "event_name" => event.fetch("event_name"),
          "outcome" => evaluation.outcome, "reason" => evaluation.reason,
          "binding_digest" => evaluation.binding_digest,
          "cursor_before" => evaluation.cursor_before, "cursor_after" => evaluation.cursor_after,
          "module_generation" => active && active["source_commit"],
          "configuration_digest" => active && active["configuration_digest"],
          "grant_digest" => configuration && ::Digest::SHA256.hexdigest(canonical(configuration.grants)),
          "concurrency" => context.dig(:hook, "concurrency"),
          "task_id" => nil, "artifacts" => [], "retry" => nil
        }
      end

      def advance_cursor(context, evaluation)
        return unless context[:hooks] && evaluation.cursor_after
        hooks = JSON.parse(canonical(context.fetch(:hooks)))
        row = hooks.dig("hooks", context.fetch(:hook_id))
        return unless row
        row["cursor"] = evaluation.cursor_after
        hooks["updated_at"] = @clock.call.utc.iso8601(6)
        Hive::AtomicFile.write(hooks_path(context.fetch(:module_name)), canonical(hooks), mode: 0o600)
      end

      def live_for_hook?(context)
        @attempt_store.scan.records.any? do |record|
          subject = record.subject
          record.live? && record.module_hook? && subject["project_id"] == @project_id &&
            subject["module"] == context.fetch(:module_name) && subject["hook"] == context.fetch(:hook_id)
        end
      end

      def persist_run(module_name, hook_attempt, event)
        data = {
          "schema_version" => 1, "run_id" => hook_attempt.run_id, "project" => @project,
          "status" => "admitting", "source_commit" => hook_attempt.subject.fetch("module_generation"),
          "configuration_digest" => hook_attempt.subject.fetch("configuration_digest"),
          "event_id" => event.fetch("event_id"), "attempt_id" => nil, "attempt_ids" => [],
          "subject" => hook_attempt.subject, "argv" => hook_attempt.argv,
          "ownership_generation" => hook_attempt.ownership_generation,
          "task_input_epoch" => hook_attempt.task_input_epoch,
          "created_at" => @clock.call.utc.iso8601(6),
          "execution_snapshot" => hook_attempt.execution_snapshot
        }
        path = run_path(module_name, hook_attempt.run_id)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        Hive::AtomicFile.write(path, canonical(data), mode: 0o600)
      end

      def update_run(module_name, hook_attempt, attempt_result, evaluation)
        path = run_path(module_name, hook_attempt.run_id)
        data = JSON.parse(File.binread(path))
        data["status"] = if attempt_result.live?
          "running"
        elsif (evaluation.nil? && attempt_result.reason == "capacity") ||
              attempt_result.reason == "launch_handoff_failed"
          "retrying"
        else
          "failed"
        end
        data["attempt_id"] = attempt_result.attempt&.attempt_id || data["attempt_id"]
        data["attempt_ids"] = (Array(data["attempt_ids"]) + [ attempt_result.attempt&.attempt_id ]).compact.uniq
        data["decision_reason"] = evaluation&.reason || data["decision_reason"]
        data["retry_charge"] = attempt_result.attempt&.[]("retry_charge")
        data["updated_at"] = @clock.call.utc.iso8601(6)
        Hive::AtomicFile.write(path, canonical(data), mode: 0o600)
      end

      def close_run(module_name, run_id, reason)
        path = run_path(module_name, run_id)
        data = JSON.parse(File.binread(path))
        data["status"] = "failed"
        data["retry"] = { "status" => "closed", "reason" => reason }
        data["updated_at"] = @clock.call.utc.iso8601(6)
        Hive::AtomicFile.write(path, canonical(data), mode: 0o600)
      end

      def read_hooks(module_name)
        bytes = File.binread(hooks_path(module_name))
        data = JSON.parse(bytes)
        unless bytes == canonical(data) && data.is_a?(Hash) && data["schema_version"] == 1 &&
               data["hooks"].is_a?(Hash)
          raise Hive::ConfigError, "module hook runtime state is malformed"
        end
        data
      rescue Errno::ENOENT
        { "schema_version" => 1, "configuration_digest" => nil, "updated_at" => nil, "hooks" => {} }
      rescue JSON::ParserError, EncodingError
        raise Hive::ConfigError, "module hook runtime state is malformed"
      end

      def required_secret_bindings(configuration)
        configuration.contract.fetch("settings").filter_map do |setting|
          next unless setting.fetch("type") == "secret" && setting.fetch("required")
          configuration.settings.fetch(setting.fetch("name"))
        end
      end

      def with_hook_lock(module_name, hook_id, shared: false)
        root = File.join(@store.runtime_path(module_name), "locks")
        FileUtils.mkdir_p(root, mode: 0o700)
        digest = ::Digest::SHA256.hexdigest("#{module_name}\0#{hook_id}")
        File.open(File.join(root, "#{digest}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue SystemCallError, IOError => e
        raise Hive::ConfigError, "module hook admission lock is unavailable: #{e.message}"
      end

      def without_hook_lock(_module_name, _hook_id)
        yield
      end

      def without_lifecycle_lock(_module_name)
        yield UNSET_SELECTION
      end

      def assert_project!(event)
        unless event["project_id"] == @project_id && event["project"] == @project
          raise Hive::ConfigError, "module event belongs to another project"
        end
      end

      def activation_barrier_path(module_name)
        File.join(@store.runtime_path(module_name), "activation-barrier.json")
      end

      def hooks_path(module_name) = File.join(@store.runtime_path(module_name), "hooks.json")
      def run_path(module_name, id) = File.join(@store.runtime_path(module_name), "runs", "#{id}.json")
      def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)

      def null_hook(id)
        {
          "id" => id, "target" => { "kind" => "entrypoint", "id" => "missing" },
          "default_enabled" => false, "schedules" => [], "events" => [], "concurrency" => "drop"
        }
      end

      class NullConfiguration
        def hooks = {}
        def settings = {}
        def grants = {}
        def contract = { "settings" => [] }
      end
    end
  end
end
