require "optparse"
require "json"
require "hive/config"
require "hive/module_package/configuration"
require "hive/module_package/managed_store"
require "hive/modules/event_ledger"
require "hive/modules/hook_attempt"
require "hive/modules/target_executor"
require "hive/workflow_package/canonical_json"

module Hive
  module Commands
    # Private detached-worker target for an admitted module hook. It rechecks
    # immutable generation/configuration identity before invoking only a
    # registered in-process entrypoint; package Ruby is never loaded.
    class ModuleHook
      def self.from_argv(argv)
        values = {}
        parser = OptionParser.new do |opts|
          %i[project event_id target_kind target generation configuration_digest run_id].each do |key|
            opts.on("--#{key.to_s.tr('_', '-')} VALUE") { |value| values[key] = value }
          end
        end
        remaining = parser.parse(argv)
        raise Hive::ConfigError, "module hook requires MODULE and HOOK" unless remaining.length == 2
        new(remaining.fetch(0), remaining.fetch(1), **values)
      rescue OptionParser::ParseError => e
        raise Hive::ConfigError, e.message
      end

      def initialize(module_name, hook_id, project:, event_id:, target_kind:, target:,
                     generation:, configuration_digest:, run_id:, target_executor: nil)
        @module_name = module_name
        @hook_id = hook_id
        @project = project
        @event_id = event_id
        @target_kind = target_kind
        @target = target
        @generation = generation
        @configuration_digest = configuration_digest
        @run_id = run_id
        @target_executor = target_executor || Hive::Modules::TargetExecutor.new
      end

      def call
        entry = Hive::Config.find_project(@project)
        raise Hive::ConfigError, "module hook project is not registered" unless entry
        store = Hive::ModulePackage::ManagedStore.new(entry.fetch("hive_state_path"))
        run = load_run(store)
        snapshot = run.fetch("execution_snapshot")
        configuration = Hive::ModulePackage::Configuration.new(snapshot.fetch("configuration"))
        hook = snapshot.fetch("descriptor")
        validate_snapshot_contract!(snapshot, configuration, hook)
        event = Hive::Modules::EventLedger.new(
          root: File.join(entry.fetch("hive_state_path"), "module-runtime")
        ).fetch(@event_id)
        raise Hive::ConfigError, "module hook event is unavailable" unless event
        validate_execution_identity!(
          entry: entry, run: run, snapshot: snapshot,
          configuration: configuration, hook: hook, event: event
        )
        @target_executor.call(
          target: hook.fetch("target"), target_snapshot: snapshot.fetch("target"),
          project: entry, module_name: @module_name, hook_id: @hook_id,
          event: event, configuration: configuration
        )
      end

      private

      def load_run(store)
        unless @run_id.to_s.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::ConfigError, "module hook run identity is malformed"
        end
        path = File.join(store.runtime_path(@module_name), "runs", "#{@run_id}.json")
        bytes = File.binread(path)
        run = JSON.parse(bytes)
        unless bytes == Hive::WorkflowPackage::CanonicalJSON.generate(run)
          raise Hive::ConfigError, "module hook execution snapshot is unavailable"
        end
        unless run["run_id"] == @run_id && run["event_id"] == @event_id &&
               run["source_commit"] == @generation && run["configuration_digest"] == @configuration_digest
          raise Hive::ConfigError, "module hook execution snapshot identity does not match"
        end
        run
      rescue Errno::ENOENT, JSON::ParserError, KeyError
        raise Hive::ConfigError, "module hook execution snapshot is unavailable"
      end

      def validate_execution_identity!(entry:, run:, snapshot:, configuration:, hook:, event:)
        target = hook.fetch("target")
        unless entry.fetch("name") == @project &&
               event.fetch("event_id") == @event_id &&
               event.fetch("project") == @project &&
               event.fetch("project_id") == entry.fetch("project_id")
          raise Hive::ConfigError, "module hook project or event identity does not match"
        end

        expected_subject = Hive::Modules::HookAttempt.subject_for(
          project_id: entry.fetch("project_id"), module_name: @module_name, hook: hook,
          module_generation: @generation, configuration: configuration, event: event
        )
        expected_run_id = Hive::Modules::HookAttempt.run_id_for(expected_subject)
        expected_argv = Hive::Modules::HookAttempt.argv_for(
          project: @project, module_name: @module_name, hook_id: @hook_id,
          event_id: @event_id, target: target, module_generation: @generation,
          configuration_digest: @configuration_digest, run_id: @run_id
        )
        epoch = snapshot.fetch("task_input_epoch")
        expected_ownership = "#{epoch}:#{@generation}"
        unless expected_run_id == @run_id &&
               run.fetch("schema_version") == 1 && run.fetch("project") == @project &&
               run.fetch("subject") == expected_subject &&
               snapshot.fetch("subject") == expected_subject &&
               run.fetch("argv") == expected_argv &&
               run.fetch("ownership_generation") == expected_ownership &&
               snapshot.fetch("ownership_generation") == expected_ownership &&
               run.fetch("task_input_epoch") == epoch
          raise Hive::ConfigError, "module hook admitted identity does not match"
        end
        true
      rescue KeyError, TypeError, ArgumentError
        raise Hive::ConfigError, "module hook execution snapshot identity does not match"
      end

      def validate_snapshot_contract!(snapshot, configuration, hook)
        Hive::Modules::HookAttempt.validate_execution_snapshot!(snapshot)
        target = hook.fetch("target")
        generation = configuration.generation
        valid = configuration.digest == @configuration_digest &&
          generation.fetch("name") == @module_name &&
          generation.fetch("source_commit") == @generation &&
          hook.fetch("id") == @hook_id &&
          configuration.contract.fetch("hooks").find { |row| row.fetch("id") == @hook_id } == hook &&
          snapshot.fetch("grants") == configuration.grants &&
          target.fetch("kind") == @target_kind && target.fetch("id") == @target &&
          snapshot.dig("target", "kind") == @target_kind &&
          snapshot.dig("target", "id") == @target
        raise Hive::ConfigError, "module hook execution snapshot identity does not match" unless valid

        true
      rescue KeyError, TypeError, ArgumentError
        raise Hive::ConfigError, "module hook execution snapshot identity does not match"
      end
    end
  end
end
