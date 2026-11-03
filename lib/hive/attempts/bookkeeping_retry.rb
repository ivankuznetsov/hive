require "hive/attempts/contracts"
require "hive/runtime_control_plane/file_fence"

module Hive
  module Attempts
    # Internal TEMPFAIL, deliberately distinct from agent/provider failures.
    # The owner persists this reason through PendingBookkeeping when SQL cannot
    # record it. It never grants permission to execute or replace a worker.
    class BookkeepingBusy < RepositoryError
      attr_reader :operation, :attempt_id, :retry_count, :elapsed_sec, :budget_sec, :reason

      def initialize(operation:, attempt_id:, retry_count:, elapsed_sec:, budget_sec:, reason: "runtime_bookkeeping_busy")
        unless %w[runtime_bookkeeping_busy first_heartbeat_owner_unverifiable_ceiling].include?(reason)
          raise ArgumentError, "unsupported bookkeeping failure reason"
        end
        @reason = reason
        @operation, @attempt_id = operation.to_s, attempt_id&.to_s
        @retry_count, @elapsed_sec, @budget_sec = retry_count, elapsed_sec, budget_sec
        super("#{reason}: #{@operation} exhausted after #{@elapsed_sec.round(3)}s " \
              "(#{@retry_count} busy tries)")
      end

      def exit_code = Hive::ExitCodes::TEMPFAIL
    end

    # One operation, one monotonic deadline, including every nested SQL try.
    # #try is the scheduled interface: heartbeat callers can drain output and
    # observe cancellation between tries. #run is for pre-start/terminal writes.
    class BookkeepingRetry
      PRESTART_BUDGET_SEC = 30
      WORKER_ALIVE_BUDGET_SEC = 600
      MAX_TRY_SEC = 1.0
      MIN_DELAY_SEC = 0.05
      LIFECYCLE_MARGIN_SEC = 0.001
      attr_reader :deadline, :retry_count, :budget_sec

      def self.prestart_budget(value)
        budget = Float(value)
        raise ArgumentError, "bookkeeping budget must be positive and finite" unless budget.finite? && budget.positive?

        [ budget, PRESTART_BUDGET_SEC ].min
      end

      def self.busy?(error)
        Hive::InternalError.sqlite_busy?(error) ||
          Hive::InternalError.exception_chain(error).any? do |entry|
            entry.is_a?(RuntimeControlPlane::FileFence::Busy)
          end
      end

      # A process-local handoff scope, not a retry scope. The launcher exports
      # the same absolute monotonic deadline to the detached wrapper.
      def self.launch_deadline = Thread.current[:hive_launch_bookkeeping_deadline]

      def self.with_launch_deadline(deadline)
        prior = launch_deadline
        Thread.current[:hive_launch_bookkeeping_deadline] = prior ? [ prior, deadline ].min : deadline
        yield
      ensure
        Thread.current[:hive_launch_bookkeeping_deadline] = prior
      end

      def initialize(operation:, attempt_id: nil, budget_sec: PRESTART_BUDGET_SEC, deadline: nil,
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     sleeper: ->(seconds) { sleep(seconds) }, random: -> { Random.rand })
        @budget_sec = Float(budget_sec)
        raise ArgumentError, "bookkeeping budget must be positive and finite" unless @budget_sec.finite? && @budget_sec.positive?

        @operation, @attempt_id = operation, attempt_id
        @monotonic, @sleeper, @random = monotonic, sleeper, random
        @started_at = @monotonic.call
        @deadline = [ @started_at + @budget_sec, deadline || Float::INFINITY ].min
        @retry_count = 0
        @last_error = nil
      end

      def cap_lifecycle!(expires_at:, now:)
        return self unless expires_at

        @deadline = [ @deadline, @monotonic.call + (expires_at - now) - LIFECYCLE_MARGIN_SEC ].min
        exhaust! unless remaining.positive?
        self
      end

      def remaining = [ deadline - @monotonic.call, 0.0 ].max

      # Nested reads, fences and mutations spend the same try's allowance.
      # Spending one try reschedules while the outer deadline still has time.
      def timeout_sec
        available = [ deadline, @try_deadline || deadline ].min - @monotonic.call
        raise RuntimeControlPlane::FileFence::Busy, "bookkeeping try budget expired" unless available.positive?

        [ MAX_TRY_SEC, available ].min
      end
      def delay
        base = [ MIN_DELAY_SEC * (2**(retry_count - 1).clamp(0, 5)), 1.0 ].min
        [ base * (0.8 + 0.4 * @random.call), 1.0 ].min
      end
      def diagnostic_try_bound = (budget_sec / (MIN_DELAY_SEC * 0.8)).ceil + 1

      def try
        exhaust! unless remaining.positive?
        @deferred = false
        @try_deadline = @monotonic.call + [ MAX_TRY_SEC, remaining ].min
        yield timeout_sec
      rescue BookkeepingBusy
        raise
      rescue StandardError => error
        raise unless self.class.busy?(error)

        @last_error = error
        @retry_count += 1
        exhaust! unless remaining.positive?
        @deferred = true
        nil
      end

      def run
        loop do
          result = self.try { |timeout| yield timeout }
          return result unless @deferred

          @sleeper.call([ delay, remaining ].min)
        end
      end

      private

      def exhaust!
        raise BookkeepingBusy.new(
          operation: @operation, attempt_id: @attempt_id, retry_count: retry_count,
          elapsed_sec: @monotonic.call - @started_at, budget_sec: budget_sec
        ), cause: @last_error
      end
    end
  end
end
