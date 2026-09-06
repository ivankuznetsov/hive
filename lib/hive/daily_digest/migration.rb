require "time"
require "hive/config"
require "hive/daily_digest/calendar"

module Hive
  module DailyDigest
    # Conservative host-zone discovery. It accepts only identifiers present in
    # TZInfo's IANA catalog; offsets and abbreviations are intentionally
    # rejected because they cannot preserve DST-aware historical boundaries.
    class TimeZoneDetector
      def initialize(environment: ENV, timezone_file: "/etc/timezone", localtime_file: "/etc/localtime")
        @environment = environment
        @timezone_file = timezone_file
        @localtime_file = localtime_file
      end

      def call
        candidates.each do |candidate|
          next if candidate.nil? || candidate.empty?

          normalized = candidate.sub(/\A:/, "").sub(%r{\A(?:posix|right)/}, "")
          begin
            Calendar.timezone!(normalized)
            return normalized
          rescue Calendar::InvalidTimeZone
            next
          end
        end
        raise Migration::InitializationError,
              "could not detect a valid host IANA time zone; set daily_digest.time_zone and " \
              "run `hive migrate --all`"
      end

      private

      def candidates
        [
          @environment["TZ"].to_s.strip,
          timezone_file_value,
          localtime_link_value
        ]
      end

      def timezone_file_value
        return unless File.file?(@timezone_file)

        File.read(@timezone_file, 512).strip
      rescue SystemCallError, IOError, ArgumentError
        nil
      end

      def localtime_link_value
        target = File.readlink(@localtime_file)
        match = target.match(%r{(?:^|/)zoneinfo/(.+)\z})
        match && match[1]
      rescue SystemCallError, ArgumentError
        nil
      end
    end

    # Idempotent global-config initializer used by `hive migrate` and
    # `hive migrate --all`. The config update is one locked atomic write, so an
    # enabled block can never expose only half of its coverage identity.
    class Migration
      class InitializationError < DailyDigest::Error; end

      def self.ensure!
        new.call
      end

      def initialize(detector: TimeZoneDetector.new,
                     projects: Hive::Config.method(:registered_projects),
                     now: -> { Time.now.utc })
        @detector = detector
        @projects = projects
        @now = now
      end

      def call
        result = nil
        Hive::Config.update_global_config! do |data|
          raw = data["daily_digest"]
          if !raw.nil? && !raw.is_a?(Hash)
            raise InitializationError, "daily_digest must be a Hash before it can be initialized"
          end
          raw = (raw || {}).dup
          if initialized?(raw)
            result = raw
            next
          end

          zone = raw["time_zone"] || @detector.call
          begin
            calendar = Calendar.new(time_zone: zone)
          rescue Calendar::InvalidTimeZone => error
            raise InitializationError, error.message
          end
          instant = normalize_now(@now.call)
          local_date = calendar.local_date_at(instant)
          interval = calendar.interval_for(local_date, sequence: 1)
          membership = normalize_membership(@projects.call)
          result = raw.merge(
            "enabled" => raw.fetch("enabled", false),
            "time_zone" => zone,
            "coverage_started_at" => instant.iso8601(6),
            "initial_membership" => membership,
            "first_interval" => interval
          )
          data["daily_digest"] = result
        end
        result
      rescue Hive::ConfigError, DailyDigest::Error => error
        raise InitializationError, "daily digest initialization failed: #{error.message}"
      end

      private

      def initialized?(raw)
        raw["time_zone"].is_a?(String) && !raw["time_zone"].empty? &&
          raw["coverage_started_at"].is_a?(String) &&
          raw["initial_membership"].is_a?(Array) && raw["first_interval"].is_a?(Hash)
      end

      def normalize_now(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc
      rescue ArgumentError, TypeError
        raise InitializationError, "daily digest migration clock is invalid"
      end

      def normalize_membership(projects)
        Array(projects).filter_map do |project|
          next unless project.is_a?(Hash)

          %w[name project_id registration_id path hive_state_path repository_identity registered_at]
            .each_with_object({}) do |key, out|
              out[key] = project[key] if project.key?(key)
            end
        end.sort_by { |project| [ project["name"].to_s, project["project_id"].to_s ] }
      end
    end
  end
end
