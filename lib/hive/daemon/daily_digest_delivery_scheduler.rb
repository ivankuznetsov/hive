require "time"
require "tzinfo"
require "hive/daemon/digest_scheduler_base"
require "hive/daily_digest/delivery_ledger"
require "hive/daily_digest/store"
require "hive/paths"

module Hive
  module Daemon
    # Opt-in recap scheduler. It walks the persisted interval sequence and
    # targets the immediately preceding closed record; label arithmetic would
    # be wrong after an east/west/date-line zone cutover.
    class DailyDigestDeliveryScheduler < DigestSchedulerBase
      STAGE = "daily_digest_delivery".freeze
      PROJECT = "daily_digest_delivery".freeze
      DEFAULT_HOUR = 9
      TERMINAL_OUTCOMES = %w[sent suppressed_empty unknown failed].freeze
      SCHEDULER_CONTRACT = {
        project: PROJECT,
        stage: STAGE,
        command: "hive digest send",
        failure_event: :daily_digest_delivery_failure_backoff,
        state_unreadable_event: :daily_digest_delivery_state_unreadable
      }.freeze

      def initialize(state_path: nil, clock: -> { Time.now.utc }, enabled: false,
                     hour: DEFAULT_HOUR, logger: nil,
                     store: Hive::DailyDigest::Store.new,
                     ledger: Hive::DailyDigest::DeliveryLedger.new)
        super(
          state_path: state_path || File.join(
            Hive::Paths.state_home, "daily_digest_delivery_state.json"
          ),
          clock: clock, enabled: enabled, logger: logger
        )
        @hour = valid_hour(hour)
        @store = store
        @ledger = ledger
        @pending_records = {}
        @reconciliation_ready = false
        reconcile_delivery_ledger(now: @clock.call) if @enabled
      end

      def reconfigure(enabled:, hour:)
        next_hour = valid_hour(hour)
        was_enabled = @enabled
        @enabled = enabled == true
        @hour = next_hour
        @reconciliation_ready = false unless @enabled
        reconcile_delivery_ledger(now: @clock.call) if @enabled && !was_enabled
      end

      def tick(now: @clock.call)
        return [] unless @enabled
        unless @reconciliation_ready
          return [] if backed_off?(now)
          return [] unless reconcile_delivery_ledger(now: now)
        end
        return [] if pending_any? || backed_off?(now)

        target = preceding_closed_record(now)
        return [] unless target
        return [] unless due?(now, target.fetch(:current_interval))

        record = target.fetch(:record)
        state = read_state
        return [] if state["last_record_id"] == record.fetch("record_id")

        date = record.fetch("local_date")
        pending_for(nil)[date] = true
        @pending_records[date] = record.fetch("record_id")
        [ dispatch_for(Date.iso8601(date)) ]
      end

      def cancel(date:, stage: nil)
        key = digest_date(date)
        @pending_records.delete(key)
        super(date: date, stage: stage)
      end

      def complete(date:, exit_code:, envelope: nil, now: @clock.call, stage: nil)
        local_date = digest_date(date)
        record_id = @pending_records[local_date] || record_id_for(local_date)
        return unless @enabled
        return unless reconcile_delivery_ledger(now: now)
        unless exit_code && exit_code.to_i.zero?
          record_failure(now)
          return
        end
        unless successful_envelope?(envelope, local_date:, record_id:)
          record_failure(now)
          return
        end

        write_state(
          "last_fired_date" => local_date,
          "last_record_id" => record_id,
          "last_outcome" => envelope.fetch("outcome"),
          "updated_at" => now.utc.iso8601(6)
        )
        clear_stage_failure(stage)
      rescue StandardError
        record_failure(now)
        raise
      ensure
        @pending_records.delete(local_date) if defined?(local_date) && local_date
        pending_for(stage).delete(local_date) if defined?(local_date) && local_date
      end

      private

      def preceding_closed_record(now)
        instant = now.utc
        intervals = @store.intervals
        current_index = intervals.index do |interval|
          utc(interval.fetch("starts_at")) <= instant && instant < utc(interval.fetch("ends_at"))
        end
        return nil unless current_index&.positive?

        current = intervals.fetch(current_index)
        previous = intervals.fetch(current_index - 1)
        record = @store.read(previous.fetch("local_date"))
        return nil unless record.fetch("lifecycle") == "closed"

        { current_interval: current, record: record }
      rescue Hive::DailyDigest::MissingRecord
        nil
      end

      def due?(now, interval)
        zone = TZInfo::Timezone.get(interval.fetch("time_zone"))
        zone.utc_to_local(now.utc).hour >= @hour
      rescue TZInfo::InvalidTimezoneIdentifier
        false
      end

      def record_id_for(date)
        record = @store.read(date)
        return record.fetch("record_id") if record.fetch("lifecycle") == "closed"

        nil
      rescue Hive::DailyDigest::Error
        nil
      end

      def reconcile_delivery_ledger(now:)
        @ledger.reconcile_interrupted(now: now)
        @reconciliation_ready = true
      rescue StandardError => error
        @reconciliation_ready = false
        @logger&.event(
          :daily_digest_delivery_state_unreadable,
          component: "delivery_ledger", error_class: error.class.name
        )
        record_failure(now)
        false
      end

      def successful_envelope?(envelope, local_date:, record_id:)
        envelope.is_a?(Hash) &&
          envelope["schema"] == "hive-digest-send" &&
          envelope["schema_version"] == 1 &&
          envelope["ok"] == true &&
          envelope["local_date"] == local_date &&
          envelope["record_id"] == record_id &&
          TERMINAL_OUTCOMES.include?(envelope["outcome"])
      end

      def valid_hour(value)
        hour = Integer(value)
        return hour if hour.between?(0, 23)

        raise ArgumentError
      rescue ArgumentError, TypeError
        raise ArgumentError, "daily digest delivery hour must be an integer between 0 and 23"
      end

      def utc(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      end

      def scheduler_contract = SCHEDULER_CONTRACT
    end
  end
end
