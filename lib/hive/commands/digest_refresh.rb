require "json"
require "hive/daily_digest/coordinator"

module Hive
  module Commands
    # Explicit mutation boundary for operators and the daemon. Ordinary
    # `hive digest` reads never instantiate this class.
    class DigestRefresh
      def initialize(date: nil, json: false, coordinator: DailyDigest::Coordinator.new,
                     stdout: $stdout)
        @date = date
        @json = json
        @coordinator = coordinator
        @stdout = stdout
      end

      def call!
        results = @coordinator.refresh(date: @date)
        envelope = {
          "schema" => "hive-digest-refresh",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-digest-refresh"),
          "ok" => true, "results" => results
        }
        if @json
          @stdout.puts(JSON.generate(envelope))
        else
          results.each do |result|
            @stdout.puts("#{result.fetch('local_date')} #{result.fetch('status')}")
          end
        end
        @emitted = true if @json
        envelope
      rescue Hive::Error => error
        emit_error(error) if @json && !@emitted
        raise
      rescue StandardError => error
        wrapped = Hive::InternalError.new(
          "hive digest refresh failed: #{error.class}: #{error.message}"
        )
        emit_error(wrapped) if @json && !@emitted
        raise wrapped
      end

      alias call call!

      private

      def emit_error(error)
        @stdout.puts(
          JSON.generate(
            Hive::Schemas::ErrorEnvelope.build(
              schema: "hive-digest-refresh", error: error,
              error_kind: error_kind(error)
            )
          )
        )
        @emitted = true
      rescue Errno::EPIPE
        @emitted = true
      end

      def error_kind(error)
        case error
        when DailyDigest::Coordinator::Disabled then "disabled"
        when DailyDigest::Coordinator::NotInitialized then "not_initialized"
        when DailyDigest::Coordinator::FutureDate then "future_date"
        when DailyDigest::MissingRecord then "missing"
        when DailyDigest::InvalidRecord then "invalid_date"
        when Hive::ConfigError then "config"
        when Hive::InternalError then "internal"
        else "digest_error"
        end
      end
    end
  end
end
