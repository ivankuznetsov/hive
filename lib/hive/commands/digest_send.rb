require "date"
require "json"
require "hive/daily_digest/delivery"

module Hive
  module Commands
    # Explicit delivery mutation. The sibling Digest command remains a pure
    # read and never requires this file or any Telegram dependency.
    class DigestSend
      SCHEMA = "hive-digest-send".freeze

      def initialize(date: nil, json: false, output: $stdout,
                     delivery: Hive::DailyDigest::Delivery.new, **options)
        @date = date
        @json = json
        @output = output
        @delivery = delivery
        @retry_requested = options.fetch(:retry, false) == true
        @emitted = false
      end

      def call
        validate_date!
        result = @delivery.deliver(date: @date, retry_requested: @retry_requested)
        payload = success_payload(result)
        if @json
          emit(payload)
        else
          @output.puts(text_summary(result))
        end
        payload
      rescue Hive::Error => error
        emit_error(error) if @json && !@emitted
        raise
      rescue StandardError => error
        wrapped = Hive::InternalError.new(
          "hive digest send failed: #{error.class}: #{error.message}"
        )
        emit_error(wrapped) if @json && !@emitted
        raise wrapped
      end

      private

      def validate_date!
        raise Hive::UsageError, "hive digest send requires --date YYYY-MM-DD" if @date.to_s.empty?

        @date = Date.iso8601(@date.to_s).iso8601
      rescue Date::Error
        raise Hive::UsageError, "invalid digest date #{@date.inspect}"
      end

      def success_payload(result)
        {
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          "local_date" => result.local_date,
          "record_id" => result.record_id,
          "amendment_frontier" => result.amendment_frontier,
          "payload_hash" => result.payload_hash,
          "outcome" => result.outcome,
          "attempt" => result.attempt,
          "deduplicated" => result.deduplicated,
          "retry_requested" => result.retry_requested,
          "web_url" => result.web_url
        }
      end

      def text_summary(result)
        case result.outcome
        when "sent"
          result.deduplicated ?
            "Digest #{result.local_date} was already sent." :
            "Sent digest #{result.local_date}."
        when "suppressed_empty"
          "Digest #{result.local_date} is complete and empty; Telegram was suppressed."
        when "unknown"
          "Digest #{result.local_date} delivery outcome is unknown; use --retry only after checking Telegram."
        when "failed"
          "Digest #{result.local_date} reached its bounded retry limit; use --retry to try again explicitly."
        else
          "Digest #{result.local_date} delivery outcome: #{result.outcome}."
        end
      end

      def emit(payload)
        @output.puts(JSON.generate(payload))
        @emitted = true
      rescue Errno::EPIPE, JSON::GeneratorError
        @emitted = true
      end

      def emit_error(error)
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: SCHEMA, error: error, error_kind: error_kind(error)
        )
        payload["remediation"] = if error.is_a?(Hive::DailyDigest::Delivery::NotClosed)
          "hive digest refresh --date #{@date}"
        end
        payload["automatic_retry_limit"] = if error.is_a?(Hive::DailyDigest::Delivery::DeliveryFailed)
          Hive::DailyDigest::DeliveryLedger::MAX_AUTOMATIC_ATTEMPTS
        end
        emit(payload)
      end

      def error_kind(error)
        case error
        when Hive::UsageError then "usage"
        when Hive::DailyDigest::MissingRecord then "missing"
        when Hive::DailyDigest::PrunedRecord then "pruned"
        when Hive::DailyDigest::Delivery::NotClosed then "not_closed"
        when Hive::DailyDigest::Delivery::DeliveryFailed then "delivery_failed"
        when Hive::DailyDigest::Delivery::InFlight then "delivery_in_flight"
        when Hive::ConfigError then "config"
        when Hive::DailyDigest::Error then "digest_error"
        else "internal"
        end
      end
    end
  end
end
