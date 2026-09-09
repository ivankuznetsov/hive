module Hive
  module Warnings
    ACTIVE_SINK_KEY = :hive_active_warning_sink
    private_constant :ACTIVE_SINK_KEY

    module_function

    def emit(message, sink: nil)
      target = sink || active_sink
      return Kernel.warn(message) unless target

      target << message.to_s
    end

    def with_sink(sink)
      return yield unless sink

      thread = Thread.current
      previous = thread.thread_variable_get(ACTIVE_SINK_KEY)
      thread.thread_variable_set(ACTIVE_SINK_KEY, sink)
      yield
    ensure
      thread&.thread_variable_set(ACTIVE_SINK_KEY, previous)
    end

    def active_sink
      Thread.current.thread_variable_get(ACTIVE_SINK_KEY)
    end
    private_class_method :active_sink
  end
end
