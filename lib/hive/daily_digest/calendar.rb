require "date"
require "digest"
require "json"
require "time"
require "tzinfo"
require "hive/daily_digest"

module Hive
  module DailyDigest
    # Resolves persisted digest labels to exact half-open UTC intervals without
    # changing ENV["TZ"] or relying on the process-local zone. The resulting
    # hashes are storage-ready: historical readers never need to recalculate a
    # boundary from current configuration.
    class Calendar
      class InvalidTimeZone < DailyDigest::Error; end
      class InvalidInterval < DailyDigest::Error; end

      attr_reader :time_zone

      def initialize(time_zone:)
        @time_zone = String(time_zone)
        @timezone = self.class.timezone!(@time_zone)
      end

      def interval_for(local_date, sequence: nil)
        date = parse_date(local_date)
        starts_at = local_midnight_utc(date)
        ends_at = local_midnight_utc(date.next_day)
        build_interval(
          local_date: date,
          starts_at: starts_at,
          ends_at: ends_at,
          sequence: sequence,
          boundary_kind: "calendar_day"
        )
      end

      def local_date_at(instant)
        time = instant.is_a?(Time) ? instant : Time.iso8601(instant.to_s)
        @timezone.utc_to_local(time.utc).to_date
      rescue ArgumentError, TypeError
        raise InvalidInterval, "invalid digest instant #{instant.inspect}"
      end

      def self.cutover_interval(previous:, time_zone:, requested_at:, sequence: nil)
        prior_date = Date.iso8601(previous.fetch("local_date"))
        effective_at = Time.iso8601(previous.fetch("ends_at")).utc
        zone = timezone!(time_zone)
        wall_date = zone.utc_to_local(effective_at).to_date
        label = [ prior_date.next_day, wall_date ].max
        calendar = new(time_zone: time_zone)
        ends_at = calendar.send(:local_midnight_utc, label.next_day)
        if ends_at <= effective_at
          raise InvalidInterval,
                "zone cutover for #{time_zone} does not end after #{effective_at.iso8601(6)}"
        end

        skipped = []
        cursor = prior_date.next_day
        while cursor < label
          skipped << cursor.iso8601
          cursor = cursor.next_day
        end
        calendar.send(
          :build_interval,
          local_date: label,
          starts_at: effective_at,
          ends_at: ends_at,
          sequence: sequence || next_sequence(previous),
          boundary_kind: "zone_cutover",
          cutover: {
            "requested_at" => normalize_time(requested_at),
            "effective_at" => normalize_time(effective_at),
            "previous_time_zone" => previous.fetch("time_zone"),
            "skipped_labels" => skipped
          }
        )
      rescue Date::Error, KeyError, TypeError, ArgumentError => error
        raise InvalidInterval, "invalid zone cutover interval: #{error.message}"
      end

      def self.timezone!(identifier)
        value = String(identifier)
        raise InvalidTimeZone, "IANA time zone must not be blank" if value.strip.empty?

        TZInfo::Timezone.get(value)
      rescue TZInfo::InvalidTimezoneIdentifier, TypeError, ArgumentError
        raise InvalidTimeZone, "unknown IANA time zone #{identifier.inspect}"
      end

      def self.normalize_time(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      end

      def self.next_sequence(previous)
        value = previous["sequence"]
        value.is_a?(Integer) ? value + 1 : nil
      end
      private_class_method :next_sequence

      private

      def parse_date(value)
        value.is_a?(Date) ? value : Date.iso8601(value.to_s)
      rescue Date::Error, TypeError
        raise InvalidInterval, "invalid digest local date #{value.inspect}"
      end

      # TZInfo represents a local wall clock as a UTC-valued Time whose fields
      # are interpreted without its offset. Ambiguous midnight selects the
      # earliest real instant. A skipped midnight selects the first valid wall
      # instant of that date; a completely skipped civil date therefore yields
      # the same boundary as its successor and a zero-duration ordinary label,
      # which the calendar sequence can record as skipped rather than overlap.
      def local_midnight_utc(date)
        wall = Time.utc(date.year, date.month, date.day)
        periods = @timezone.periods_for_local(wall)
        return periods.map { |period| wall - period.utc_total_offset }.min.utc unless periods.empty?

        1.upto(48 * 60) do |minute|
          candidate = wall + (minute * 60)
          candidate_periods = @timezone.periods_for_local(candidate)
          next if candidate_periods.empty?

          return candidate_periods.map { |period| candidate - period.utc_total_offset }.min.utc
        end
        raise InvalidInterval, "could not resolve midnight for #{date} in #{time_zone}"
      end

      def build_interval(local_date:, starts_at:, ends_at:, sequence:, boundary_kind:, cutover: nil)
        duration = (ends_at - starts_at).to_i
        raise InvalidInterval, "digest interval duration cannot be negative" if duration.negative?

        interval = {
          "interval_id" => nil,
          "local_date" => local_date.iso8601,
          "sequence" => sequence,
          "time_zone" => time_zone,
          "starts_at" => self.class.normalize_time(starts_at),
          "ends_at" => self.class.normalize_time(ends_at),
          "duration_seconds" => duration,
          "boundary_kind" => boundary_kind,
          "cutover" => cutover
        }
        identity_bytes = interval.reject { |key, _| key == "interval_id" }
                                 .sort.to_h
                                 .then { |value| JSON.generate(value) }
        interval["interval_id"] = Digest::SHA256.hexdigest(identity_bytes)
        interval.freeze
      end
    end
  end
end
