require "hive/patrol_fix"

module Hive
  module PatrolFix
    # Stable first-party dispatch seam. Later controller units register the
    # concrete stage handlers; generic workflow agents never own these stages.
    module Runner
      module_function

      STAGE_FILES = {
        "inbox" => "hive/stages/patrol_fix/inbox",
        "fix" => "hive/stages/patrol_fix/fix",
        "validate" => "hive/stages/patrol_fix/validate",
        "review" => "hive/stages/patrol_fix/review",
        "publish" => "hive/stages/patrol_fix/publish"
      }.freeze

      def run!(task, cfg = nil, **kwargs)
        if defined?(Hive::PatrolFix::Transition)
          Hive::PatrolFix::Transition.new(task).reconcile!
        else
          require "hive/patrol_fix/transition"
          Hive::PatrolFix::Transition.new(task).reconcile!
        end
        load_handler(task.stage_name)
        handler = handlers[task.stage_name]
        unless handler
          raise Hive::StageError,
                "patrol-fix controller for stage #{task.stage_name} is not available"
        end

        handler.call(task, cfg || {}, **kwargs)
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

      def load_handler(stage)
        file = STAGE_FILES[stage.to_s]
        return unless file
        return if handlers.key?(stage.to_s)

        require file
        constant = {
          "inbox" => :Inbox, "fix" => :Fix, "validate" => :Validate,
          "review" => :Review, "publish" => :Publish
        }.fetch(stage.to_s)
        handlers[stage.to_s] = Hive::Stages::PatrolFix.const_get(constant).method(:run!)
      end
      private_class_method :load_handler
    end
  end
end
