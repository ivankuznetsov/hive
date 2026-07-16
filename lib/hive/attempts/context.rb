require "hive/attempts/store"

module Hive
  module Attempts
    # Trusted, process-local identity installed by the durable supervisor.
    # Stage workers remain lease-unaware; compatibility projections ask this
    # object for optional attempt fields when writing locks and markers.
    class Context
      THREAD_KEY = :hive_attempt_context

      attr_reader :attempt_id, :task_generation

      def self.current
        explicit = Thread.current[THREAD_KEY]
        return explicit if explicit
        return nil unless ENV["HIVE_ATTEMPT_INTERNAL"] == "1"

        attempt_id = ENV["HIVE_ATTEMPT_ID"].to_s
        root = ENV["HIVE_ATTEMPT_STORE_ROOT"].to_s
        return nil if attempt_id.empty? || root.empty?

        record = Store.new(root: root).fetch(attempt_id)
        return nil unless record && record.attempt_id == attempt_id

        new(attempt_id: record.attempt_id, task_generation: record.task_generation)
      rescue Hive::Error, SystemCallError
        nil
      end

      def self.active?
        !current.nil?
      end

      def self.projection
        context = current
        return {} unless context

        {
          "attempt_id" => context.attempt_id,
          "task_generation" => context.task_generation
        }
      end

      def self.with(attempt_id:, task_generation:)
        previous = Thread.current[THREAD_KEY]
        Thread.current[THREAD_KEY] = new(
          attempt_id: attempt_id,
          task_generation: task_generation
        )
        yield
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      def initialize(attempt_id:, task_generation:)
        @attempt_id = attempt_id.to_s
        @task_generation = task_generation.to_s
        raise ArgumentError, "attempt context requires an attempt ID" if @attempt_id.empty?
        raise ArgumentError, "attempt context requires a task generation" if @task_generation.empty?
      end
    end
  end
end
