require "date"
require "fileutils"
require "json"
require "shellwords"
require "hive/digest/window"
require "hive/paths"

module Hive
  module Daemon
    class DigestScheduler
      DIGEST_STAGE = "digest".freeze
      DIGEST_PROJECT = "digest".freeze
      DEFAULT_MAX_CATCHUP_DAYS = 7
      # Escalating backoff (seconds) after a non-zero digest exit, mirroring
      # the patrol/merge-watcher failure schedules. Without it a date that
      # keeps failing re-dispatches a paid categorizer agent every poll.
      FAILURE_BACKOFF_SCHEDULE = [ 60, 300, 900 ].freeze

      def initialize(state_path: nil, clock: -> { Time.now }, enabled: false,
                     max_catchup_days: DEFAULT_MAX_CATCHUP_DAYS, logger: nil)
        @state_path = state_path || File.join(Hive::Paths.state_home, "digest_state.json")
        @clock = clock
        @enabled = enabled == true
        @max_catchup_days = [ max_catchup_days.to_i, 0 ].max
        @logger = logger
        @pending = {}
        # Global failure backoff for the daily job (only one date is ever in
        # flight at a time): { count:, next_eligible_at: } or nil.
        @failure = nil
      end

      # Apply a SIGHUP config reload in place so an operator enabling the
      # digest (or retuning the catch-up cap) takes effect within one tick,
      # without dropping the in-memory pending/backoff state a rebuild would
      # lose. Mirrors the daemon's "takes effect within one tick" contract.
      def reconfigure(enabled:, max_catchup_days:)
        @enabled = enabled == true
        @max_catchup_days = [ max_catchup_days.to_i, 0 ].max
      end

      def tick(now: @clock.call)
        return [] unless @enabled
        return [] if @pending.any?
        return [] if backed_off?(now)

        today = Hive::Digest::Window.local_today(now: now)
        completed_day = today - 1
        state = read_state
        last = parse_date(state["last_digested_date"])

        unless last
          write_state("last_digested_date" => completed_day.iso8601)
          return []
        end

        owed = owed_days(last, completed_day)
        return [] if owed.empty?

        owed = apply_catchup_cap(owed)
        return [] if owed.empty?

        date = owed.first
        @pending[date.iso8601] = true
        [ dispatch_for(date) ]
      end

      def complete(date:, exit_code:, now: @clock.call)
        local_date = Hive::Digest::Window.parse_date(date)
        @pending.delete(local_date.iso8601)
        unless exit_code.to_i.zero?
          record_failure(now)
          return
        end

        @failure = nil
        state = read_state
        last = parse_date(state["last_digested_date"])
        return if last && last >= local_date

        write_state("last_digested_date" => local_date.iso8601, "updated_at" => now.utc.iso8601)
      end

      # Release a date the dispatcher marked pending in `tick` but then
      # gated (e.g. a concurrency backstop) before spawning, so the next
      # eligible tick can re-evaluate it. No failure is recorded — the
      # child never ran. Mirrors PatrolScheduler#cancel.
      def cancel(date:)
        @pending.delete(Hive::Digest::Window.parse_date(date).iso8601)
      end

      def pending?(date)
        @pending.key?(Hive::Digest::Window.parse_date(date).iso8601)
      end

      private

      def backed_off?(now)
        @failure && now < @failure[:next_eligible_at]
      end

      def record_failure(now)
        count = (@failure&.fetch(:count, 0)).to_i + 1
        interval = FAILURE_BACKOFF_SCHEDULE[[ count - 1, FAILURE_BACKOFF_SCHEDULE.size - 1 ].min]
        @failure = { count: count, next_eligible_at: now + interval }
        @logger&.event(
          :digest_failure_backoff,
          failures: count,
          retry_after_sec: interval,
          next_eligible_at: now.utc.iso8601
        )
      end

      def owed_days(last, completed_day)
        return [] if last >= completed_day

        ((last + 1)..completed_day).to_a
      end

      def apply_catchup_cap(owed)
        return owed if @max_catchup_days.zero? || owed.size <= @max_catchup_days

        skipped = owed.first(owed.size - @max_catchup_days)
        last_skipped = skipped.last
        write_state("last_digested_date" => last_skipped.iso8601)
        @logger&.event(
          :digest_catchup_skipped,
          skipped_from: skipped.first.iso8601,
          skipped_to: last_skipped.iso8601,
          skipped_days: skipped.size,
          max_catchup_days: @max_catchup_days
        )
        owed.last(@max_catchup_days)
      end

      def dispatch_for(date)
        iso = date.iso8601
        {
          project: DIGEST_PROJECT,
          slug: iso,
          stage: DIGEST_STAGE,
          command: "hive digest --date #{Shellwords.escape(iso)} --json",
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: nil
        }
      end

      def read_state
        return {} unless File.exist?(@state_path)

        parsed = JSON.parse(File.read(@state_path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      def write_state(data)
        FileUtils.mkdir_p(File.dirname(@state_path))
        tmp = "#{@state_path}.tmp.#{$$}"
        File.write(tmp, JSON.pretty_generate(data))
        File.rename(tmp, @state_path)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      def parse_date(value)
        value && Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
