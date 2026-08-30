require "hive/bot/logger"
require "hive/bot/telegram"
require "hive/config"
require "hive/daily_digest/delivery_ledger"
require "hive/daily_digest/reader"
require "hive/daily_digest/telegram_renderer"
require "hive/env_file"

module Hive
  module DailyDigest
    # Coordinates one recap effect after every fallible input has been
    # validated and a durable intent has been prepared. Ambiguous transport
    # outcomes become terminal `unknown` results and are never auto-retried.
    class Delivery
      class NotClosed < DailyDigest::Error; end
      class DestinationError < Hive::ConfigError; end
      class DeliveryFailed < Hive::UnavailableError; end
      class InFlight < Hive::UnavailableError; end

      Result = Data.define(
        :local_date, :record_id, :amendment_frontier, :payload_hash,
        :web_url, :outcome, :attempt, :deduplicated, :retry_requested
      )

      def initialize(
        reader: Reader.new,
        ledger: DeliveryLedger.new,
        bot_config_loader: Hive::Config.method(:load_global_bot),
        web_config_loader: Hive::Config.method(:load_global_web),
        env_loader: Hive::EnvFile,
        token_loader: Hive::Config.method(:telegram_bot_token!),
        telegram_factory: nil,
        definite_failure: nil,
        logger: nil,
        clock: -> { Time.now.utc }
      )
        @reader = reader
        @ledger = ledger
        @bot_config_loader = bot_config_loader
        @web_config_loader = web_config_loader
        @env_loader = env_loader
        @token_loader = token_loader
        @telegram_factory = telegram_factory || method(:build_telegram)
        @definite_failure = definite_failure || method(:telegram_definite_failure?)
        @logger = logger
        @clock = clock
      end

      def deliver(date:, retry_requested: false)
        record = @reader.read(date: date)
        validate_record!(record)
        rendered = TelegramRenderer.new(
          web_origin: @web_config_loader.call.fetch("origin")
        ).render(record)

        bot = @bot_config_loader.call
        chat_id = private_chat_id!(bot)
        logger = delivery_logger(bot)
        now = @clock.call
        preparation = @ledger.prepare(
          local_date: record.fetch("local_date"),
          record_id: record.fetch("record_id"),
          amendment_frontier: rendered.amendment_frontier,
          payload_hash: rendered.payload_hash,
          destination_chat_id: chat_id,
          now: now,
          retry_requested: retry_requested
        )
        if preparation.action == :in_flight
          raise InFlight, "digest #{record.fetch('local_date')} delivery is already in flight"
        end
        return prior_result(record, rendered, preparation, retry_requested:) unless
          preparation.action == :send

        attempt = preparation.receipt.fetch("attempt")
        if complete_empty?(record)
          receipt = @ledger.mark_suppressed(
            record.fetch("local_date"), attempt: attempt, now: @clock.call
          )
          log_skip(:notification_skipped_dedupe, record, outcome: "suppressed_empty")
          return result(record, rendered, receipt, deduplicated: false, retry_requested: retry_requested)
        end

        # Preparing first lets restart discovery atomically turn a leftover
        # `sending` intent into `unknown` even when credentials are currently
        # unavailable. A credential failure leaves a harmless `prepared`
        # intent that resumes the same attempt; no transport effect started.
        @env_loader.load!
        token = @token_loader.call
        telegram = @telegram_factory.call(token: token, logger: logger)
        @ledger.mark_sending(record.fetch("local_date"), attempt: attempt, now: @clock.call)
        begin
          telegram.send_message(
            chat_id: chat_id, text: rendered.text, parse_mode: rendered.parse_mode
          )
          receipt = @ledger.mark_sent(
            record.fetch("local_date"), attempt: attempt, now: @clock.call
          )
          logger&.event(
            :notification_sent, source: "daily_digest", record_id: record.fetch("record_id"),
            local_date: record.fetch("local_date"), outcome: "sent", attempt: attempt
          )
          result(record, rendered, receipt, deduplicated: false, retry_requested: retry_requested)
        rescue StandardError => error
          settle_send_error(
            error, record: record, rendered: rendered, attempt: attempt,
            retry_requested: retry_requested
          )
        end
      end

      private

      def validate_record!(record)
        status = record.fetch("reader_status", "ok")
        raise DailyDigest::MissingRecord, "digest #{record['local_date']} is missing" if status == "missing"
        raise DailyDigest::PrunedRecord, "digest #{record['local_date']} was pruned" if status == "pruned"
        return if record.fetch("lifecycle") == "closed"

        raise NotClosed, "digest #{record.fetch('local_date')} must be closed before delivery"
      end

      def private_chat_id!(bot)
        chat_id = Hive::Config.telegram_chat_id!(bot)
        unless chat_id.is_a?(Integer) && chat_id.positive? &&
               Array(bot.fetch("chat_id_allowlist")).include?(chat_id)
          raise DestinationError,
                "daily digest delivery requires bot.chat_id_allowlist[0] to be a private chat id"
        end

        chat_id
      end

      def complete_empty?(record)
        completeness = record["effective_completeness"] || record.fetch("completeness")
        content = record["effective_content"] || record.fetch("content")
        completeness == "complete" && content == "empty"
      end

      def prior_result(record, rendered, preparation, retry_requested:)
        receipt = preparation.receipt
        log_skip(
          :notification_skipped_dedupe, record,
          outcome: receipt.fetch("outcome"), action: preparation.action.to_s
        )
        result(
          record, rendered, receipt, deduplicated: preparation.action == :duplicate,
          retry_requested: retry_requested
        )
      end

      def settle_send_error(error, record:, rendered:, attempt:, retry_requested:)
        reason_code = error.class.name.to_s.gsub("::", "_").downcase.byteslice(0, 80)
        if @definite_failure.call(error)
          receipt = @ledger.mark_failed(
            record.fetch("local_date"), attempt: attempt, now: @clock.call,
            reason_code: reason_code
          )
          delivery_logger&.event(
            :send_failure, source: "daily_digest", record_id: record.fetch("record_id"),
            local_date: record.fetch("local_date"), outcome: "failed", attempt: attempt,
            error_class: error.class.name
          )
          return result(
            record, rendered, receipt, deduplicated: false,
            retry_requested: retry_requested
          ) if attempt >= DeliveryLedger::MAX_AUTOMATIC_ATTEMPTS

          raise DeliveryFailed,
                "Telegram rejected digest #{record.fetch('local_date')} (attempt #{attempt}); retry is bounded"
        end

        receipt = @ledger.mark_unknown(
          record.fetch("local_date"), attempt: attempt, now: @clock.call,
          reason_code: reason_code
        )
        delivery_logger&.event(
          :send_failure, source: "daily_digest", record_id: record.fetch("record_id"),
          local_date: record.fetch("local_date"), outcome: "unknown", attempt: attempt,
          error_class: error.class.name
        )
        result(
          record, rendered, receipt, deduplicated: false,
          retry_requested: retry_requested
        )
      end

      def telegram_definite_failure?(error)
        defined?(::Telegram::Bot::Exceptions::ResponseError) &&
          error.is_a?(::Telegram::Bot::Exceptions::ResponseError)
      end

      def result(record, rendered, receipt, deduplicated:, retry_requested:)
        Result.new(
          local_date: record.fetch("local_date"), record_id: record.fetch("record_id"),
          amendment_frontier: receipt.fetch("amendment_frontier"),
          payload_hash: receipt.fetch("payload_hash"), web_url: rendered.web_url,
          outcome: receipt.fetch("outcome"), attempt: receipt.fetch("attempt"),
          deduplicated: deduplicated, retry_requested: retry_requested == true
        )
      end

      def log_skip(event, record, **attributes)
        delivery_logger&.event(
          event, source: "daily_digest", record_id: record.fetch("record_id"),
          local_date: record.fetch("local_date"), **attributes
        )
      end

      def delivery_logger(bot = nil)
        return @logger if @logger
        return nil unless bot

        @logger = Hive::Bot::Logger.new(path: bot.fetch("log_file"))
      end

      def build_telegram(token:, logger:)
        Hive::Bot::Telegram.new(token: token, logger: logger)
      end
    end
  end
end
