require "date"
require "json"
require "shellwords"
require "hive/atomic_file"
require "hive/digest/window"

module Hive
  module Daemon
    # Shared lifecycle for the daemon's daily digest schedulers. Subclasses
    # own cadence and cursor semantics; this base owns pending-date identity,
    # failure backoff, dispatch shape, observable state reads, and atomic
    # persistence.
    class DigestSchedulerBase
      FAILURE_BACKOFF_SCHEDULE = [ 60, 300, 900 ].freeze

      def initialize(state_path:, clock:, enabled:, logger:)
        @state_path = state_path
        @clock = clock
        @enabled = enabled == true
        @logger = logger
        @pending = {}
        @failure = nil
      end

      def cancel(date:)
        @pending.delete(digest_date(date))
      end

      def pending?(date)
        @pending.key?(digest_date(date))
      end

      private

      def digest_date(date)
        Hive::Digest::Window.parse_date(date).iso8601
      end

      def backed_off?(now)
        @failure && now < @failure[:next_eligible_at]
      end

      def record_failure(now)
        count = (@failure&.fetch(:count, 0)).to_i + 1
        interval = FAILURE_BACKOFF_SCHEDULE[[ count - 1, FAILURE_BACKOFF_SCHEDULE.size - 1 ].min]
        next_eligible_at = now + interval
        @failure = { count: count, next_eligible_at: next_eligible_at }
        @logger&.event(
          scheduler_contract.fetch(:failure_event),
          failures: count,
          retry_after_sec: interval,
          next_eligible_at: next_eligible_at.utc.iso8601
        )
      end

      def dispatch_for(date)
        contract = scheduler_contract
        iso = date.iso8601
        {
          project: contract.fetch(:project),
          slug: iso,
          stage: contract.fetch(:stage),
          command: "#{contract.fetch(:command)} --date #{Shellwords.escape(iso)} --json",
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: nil
        }
      end

      def read_state
        return {} unless File.exist?(@state_path)

        parsed = JSON.parse(File.read(@state_path))
        return parsed if parsed.is_a?(Hash)

        log_state_unreadable("expected a JSON object, got #{parsed.class}")
        {}
      rescue JSON::ParserError, SystemCallError => e
        log_state_unreadable("#{e.class}: #{e.message}")
        {}
      end

      def log_state_unreadable(reason)
        @logger&.event(
          scheduler_contract.fetch(:state_unreadable_event),
          path: @state_path,
          error: reason
        )
      end

      def write_state(data)
        Hive::AtomicFile.write(@state_path, JSON.pretty_generate(data))
      end

      def scheduler_contract
        raise NotImplementedError, "#{self.class} must define its digest scheduler contract"
      end
    end
  end
end
