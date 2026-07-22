require "optparse"
require "json"
require "hive/config"
require "hive/module_package/configuration"
require "hive/module_package/managed_store"
require "hive/modules/entrypoints"
require "hive/modules/event_ledger"

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
                     generation:, configuration_digest:, run_id:)
        @module_name = module_name
        @hook_id = hook_id
        @project = project
        @event_id = event_id
        @target_kind = target_kind
        @target = target
        @generation = generation
        @configuration_digest = configuration_digest
        @run_id = run_id
      end

      def call
        entry = Hive::Config.find_project(@project)
        raise Hive::ConfigError, "module hook project is not registered" unless entry
        store = Hive::ModulePackage::ManagedStore.new(entry.fetch("hive_state_path"))
        run = load_run(store)
        snapshot = run.fetch("execution_snapshot")
        configuration = Hive::ModulePackage::Configuration.new(snapshot.fetch("configuration"))
        hook = snapshot.fetch("descriptor")
        unless hook && hook.dig("target", "kind") == @target_kind && hook.dig("target", "id") == @target
          raise Hive::ConfigError, "module hook target does not match its immutable configuration"
        end
        event = Hive::Modules::EventLedger.new(
          root: File.join(entry.fetch("hive_state_path"), "module-runtime")
        ).fetch(@event_id)
        raise Hive::ConfigError, "module hook event is unavailable" unless event
        unless @target_kind == "entrypoint"
          raise Hive::ConfigError, "module hook target kind #{@target_kind.inspect} has no registered executor"
        end
        result = Hive::Modules::Entrypoints.fetch(@target).call(
          project: entry, module_name: @module_name, hook_id: @hook_id,
          event: event, configuration: configuration
        )
        Integer(result || 0)
      end

      private

      def load_run(store)
        unless @run_id.to_s.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::ConfigError, "module hook run identity is malformed"
        end
        path = File.join(store.runtime_path(@module_name), "runs", "#{@run_id}.json")
        run = JSON.parse(File.binread(path))
        unless run["run_id"] == @run_id && run["event_id"] == @event_id &&
               run["source_commit"] == @generation && run["configuration_digest"] == @configuration_digest
          raise Hive::ConfigError, "module hook execution snapshot identity does not match"
        end
        run
      rescue Errno::ENOENT, JSON::ParserError, KeyError
        raise Hive::ConfigError, "module hook execution snapshot is unavailable"
      end
    end
  end
end
