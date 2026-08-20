require "hive/patrol_fix"

module Hive
  module PatrolFix
    # Stable first-party dispatch seam. Later controller units register the
    # concrete stage handlers; generic workflow agents never own these stages.
    module Runner
      module_function

      def run!(task, **kwargs)
        handler = handlers[task.stage_name]
        unless handler
          raise Hive::StageError,
                "patrol-fix controller for stage #{task.stage_name} is not available"
        end

        handler.call(task, **kwargs)
      end

      def register(stage, callable = nil, &block)
        handler = callable || block
        raise ArgumentError, "patrol-fix runner must be callable" unless handler.respond_to?(:call)
        raise ArgumentError, "unknown patrol-fix stage #{stage.inspect}" unless Projection::STAGE_DIRS.any? do |dir|
          dir.split("-", 2).last == stage.to_s
        end

        handlers[stage.to_s] = handler
      end

      def reset!
        @handlers = {}
      end

      def handlers
        @handlers ||= {}
      end
    end
  end
end
