require "hive/resumable_workflows/declarative"

module Hive
  module ResumableWorkflows
    module Registry
      @adapters = {}
      @mutex = Mutex.new

      module_function

      def register(kind, adapter = nil, &factory)
        value = factory || adapter
        raise ArgumentError, "resumable adapter is required" unless value

        @mutex.synchronize { @adapters[kind.to_s] = value }
      end

      def resolve(workflow)
        metadata = workflow&.resumable
        return nil unless metadata

        if metadata["adapter"]
          value = @mutex.synchronize { @adapters[metadata.fetch("adapter")] }
          raise Hive::ConfigError,
                "workflow #{workflow.id.inspect} references unknown resumable adapter " \
                "#{metadata.fetch('adapter').inspect}" unless value

          return value.respond_to?(:call) ? value.call(workflow) : value
        end

        Declarative.new(workflow: workflow, metadata: metadata)
      end

      def registered?(kind)
        @mutex.synchronize { @adapters.key?(kind.to_s) }
      end

      def reset_for_tests!
        @mutex.synchronize { @adapters.clear }
      end
    end
  end
end

require "hive/resumable_workflows/bench"
