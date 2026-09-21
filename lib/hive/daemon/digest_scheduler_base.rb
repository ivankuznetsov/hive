require "date"
require "json"
require "shellwords"
require "hive/atomic_file"
require "hive/local_date_window"

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
        @pending = Hash.new { |hash, stage| hash[stage] = {} }
        @failures = {}
      end

      def cancel(date:, stage: nil)
        local_date = digest_date(date)
        if stage
          pending_for(stage).delete(local_date)
        else
          @pending.each_value { |dates| dates.delete(local_date) }
        end
      end

      def pending?(date, stage: nil)
        local_date = digest_date(date)
        return pending_for(stage).key?(local_date) if stage

        @pending.any? { |_identity, dates| dates.key?(local_date) }
      end

      private

      def digest_date(date)
        Hive::LocalDateWindow.parse_date(date).iso8601
      end

      def backed_off?(now)
        stage_backed_off?(nil, now)
      end

      def record_failure(now)
        record_stage_failure(nil, now)
      end

      def stage_backed_off?(stage, now)
        failure = @failures[stage_identity(stage)]
        failure && now < failure.fetch(:next_eligible_at)
      end

      def record_stage_failure(stage, now)
        identity = stage_identity(stage)
        count = @failures.dig(identity, :count).to_i + 1
        interval = FAILURE_BACKOFF_SCHEDULE[[ count - 1, FAILURE_BACKOFF_SCHEDULE.size - 1 ].min]
        next_eligible_at = now + interval
        @failures[identity] = { count: count, next_eligible_at: next_eligible_at }
        @logger&.event(
          scheduler_contract.fetch(:failure_event),
          stage: identity,
          failures: count,
          retry_after_sec: interval,
          next_eligible_at: next_eligible_at.utc.iso8601
        )
      end

      def clear_stage_failure(stage)
        @failures.delete(stage_identity(stage))
      end

      def pending_for(stage)
        @pending[stage_identity(stage)]
      end

      def pending_any?
        @pending.any? { |_stage, dates| dates.any? }
      end

      def stage_identity(stage)
        (stage || scheduler_contract.fetch(:stage)).to_s
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
        # Preserve the schedulers' pre-consolidation write/rename durability
        # contract; they did not flush each cursor update to physical storage.
        Hive::AtomicFile.write(@state_path, JSON.pretty_generate(data), fsync: false)
      end

      def scheduler_contract
        raise NotImplementedError, "#{self.class} must define its digest scheduler contract"
      end
    end
  end
end
