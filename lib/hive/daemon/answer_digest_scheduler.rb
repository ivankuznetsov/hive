require "date"
require "fileutils"
require "json"
require "shellwords"
require "hive/digest/window"
require "hive/paths"

module Hive
  module Daemon
    class AnswerDigestScheduler
      ANSWER_DIGEST_STAGE = "answer_digest".freeze
      ANSWER_DIGEST_PROJECT = "answer_digest".freeze
      DEFAULT_HOUR = 9
      FAILURE_BACKOFF_SCHEDULE = [ 60, 300, 900 ].freeze

      def initialize(state_path: nil, clock: -> { Time.now }, enabled: false,
                     hour: DEFAULT_HOUR, logger: nil)
        @state_path = state_path || File.join(Hive::Paths.state_home, "answer_digest_state.json")
        @clock = clock
        @enabled = enabled == true
        @hour = clamp_hour(hour)
        @logger = logger
        @pending = {}
        @failure = nil
      end

      def reconfigure(enabled:, hour:)
        @enabled = enabled == true
        @hour = clamp_hour(hour)
      end

      def tick(now: @clock.call)
        return [] unless @enabled
        return [] if @pending.any?
        return [] if backed_off?(now)
        return [] if now.getlocal.hour < @hour

        today = Hive::Digest::Window.local_today(now: now)
        state = read_state
        last = parse_date(state["last_fired_date"])
        return [] if last && last >= today

        @pending[today.iso8601] = true
        [ dispatch_for(today) ]
      end

      def complete(date:, exit_code:, now: @clock.call)
        local_date = Hive::Digest::Window.parse_date(date)
        @pending.delete(local_date.iso8601)

        unless exit_code && exit_code.to_i.zero?
          record_failure(now)
          return
        end

        @failure = nil
        state = read_state
        last = parse_date(state["last_fired_date"])
        return if last && last >= local_date

        write_state("last_fired_date" => local_date.iso8601, "updated_at" => now.utc.iso8601)
      end

      def cancel(date:)
        @pending.delete(Hive::Digest::Window.parse_date(date).iso8601)
      end

      def pending?(date)
        @pending.key?(Hive::Digest::Window.parse_date(date).iso8601)
      end

      private

      def clamp_hour(hour)
        [ [ hour.to_i, 0 ].max, 23 ].min
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
          :answer_digest_failure_backoff,
          failures: count,
          retry_after_sec: interval,
          next_eligible_at: next_eligible_at.utc.iso8601
        )
      end

      def dispatch_for(date)
        iso = date.iso8601
        {
          project: ANSWER_DIGEST_PROJECT,
          slug: iso,
          stage: ANSWER_DIGEST_STAGE,
          command: "hive answer-digest --date #{Shellwords.escape(iso)} --json",
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
        @logger&.event(:answer_digest_state_unreadable, path: @state_path, error: reason)
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
      rescue ArgumentError => e
        # read_state only logs JSON/IO faults; a well-formed-JSON-but-malformed
        # `last_fired_date` would otherwise self-heal to nil in the dark. Log
        # it on the same event so a corrupt cursor is observable.
        log_state_unreadable("malformed last_fired_date #{value.inspect}: #{e.message}")
        nil
      end
    end
  end
end
