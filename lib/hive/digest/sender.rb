require "hive/bot/logger"
require "hive/bot/telegram"
require "hive/config"
require "hive/digest/delivery_checkpoint_store"
require "hive/paths"
require "hive/secret_patterns"

module Hive
  module Digest
    class Sender
      # `responses` and `text` exist for test/observability — the e2e asserts a
      # real Telegram message_id off `responses` and `text` echoes the sent
      # body; neither is part of the `hive digest --json` envelope, so their
      # absence from json_payload is intentional, not a bug.
      SendResult = Data.define(:chat_id, :responses, :dry_run, :text) do
        # The dry_run flag and the presence of a chat_id must agree: a dry-run
        # never resolves a recipient, and a real send always carries the one it
        # resolved (see #deliver). Guard BOTH directions at the boundary so
        # "a real send always has a recipient" is structural, not incidental.
        def initialize(chat_id:, responses:, dry_run:, text:)
          raise ArgumentError, "dry-run digest send result must not carry a chat_id" if dry_run && !chat_id.nil?
          raise ArgumentError, "a real digest send result must carry a chat_id" if !dry_run && chat_id.nil?

          super
        end
      end

      def initialize(cfg:, telegram_factory: nil, logger: nil, redactor: Hive::SecretPatterns,
                     checkpoint_root: nil, checkpoint_store: nil)
        @cfg = cfg || {}
        @telegram_factory = telegram_factory || method(:build_telegram)
        @logger = logger
        @redactor = redactor
        @checkpoint_store = checkpoint_store || DeliveryCheckpointStore.new(
          root: checkpoint_root || File.join(Hive::Paths.state_home, "digest-deliveries")
        )
      end

      # Resolve the recipient + token without sending, so callers can fail
      # fast before an expensive changelog-generator run. Raises Hive::ConfigError
      # when either is missing.
      def preflight!
        self.class.resolve_chat_id(@cfg)
        Hive::Config.telegram_bot_token!
        nil
      end

      def deliver(text, dry_run: false, digest_date: nil)
        return SendResult.new(chat_id: nil, responses: [], dry_run: true, text: text) if dry_run

        text = safe_delivery_text(text)
        chat_id = self.class.resolve_chat_id(@cfg)
        client = @telegram_factory.call(token: Hive::Config.telegram_bot_token!, logger: logger)
        responses, stable_text = @checkpoint_store.synchronize(digest_date) do |key|
          checkpoint = delivery_checkpoint(client, key, chat_id, text)
          reject_incompatible_checkpoint!(checkpoint, chat_id)
          raise_checkpoint_failure!(checkpoint)
          [ send_in_chunks(client, chat_id, checkpoint), checkpoint.fetch("payload") ]
        end
        SendResult.new(chat_id: chat_id, responses: responses, dry_run: false, text: stable_text)
      end

      def self.resolve_chat_id(cfg)
        bot = cfg.fetch("bot", {})
        chat_id = Array(bot["chat_id_allowlist"]).first
        return chat_id unless blank?(chat_id)

        raise Hive::ConfigError,
              "bot.chat_id_allowlist[0] must be configured before sending digest"
      end

      # Internal helper for resolve_chat_id only; not part of the public
      # surface (callers use resolve_chat_id / preflight!).
      def self.blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
      private_class_method :blank?

      private

      def safe_delivery_text(text)
        redacted = @redactor.redact(text.to_s)
        unless @redactor.scan(redacted).empty?
          raise Hive::ConfigError, "digest delivery redaction could not be verified"
        end
        redacted.gsub(/(?<!\\)\[REDACTED:([a-z0-9_]+)(?<!\\)\]/i, '\\\\[REDACTED:\1\\\\]')
      rescue EncodingError, SystemCallError
        raise Hive::ConfigError, "digest delivery redaction failed"
      end

      def delivery_checkpoint(client, key, chat_id, text)
        @checkpoint_store.load(key) || @checkpoint_store.create(
          key: key,
          chat_id: chat_id,
          payload: text,
          chunks: markdown_v2_chunks(client, text)
        )
      end

      def markdown_v2_chunks(client, text)
        if client.respond_to?(:message_chunks)
          client.message_chunks(text, parse_mode: :markdown_v2)
        else
          [ text ]
        end
      rescue Hive::Bot::Telegram::MarkdownV2SplitError => e
        raise PermanentDeliveryError, "hive digest: #{e.message}"
      end

      def reject_incompatible_checkpoint!(checkpoint, chat_id)
        return if checkpoint.fetch("chat_id").to_s == chat_id.to_s

        raise PermanentDeliveryCheckpointError,
              "hive digest: checkpoint recipient differs from configured Telegram chat"
      end

      def raise_checkpoint_failure!(checkpoint)
        failure = checkpoint["permanent_failure"]
        if failure
          raise PermanentDeliveryError,
                "hive digest: delivery is parked after " \
                "#{failure.fetch('error_class')}: #{failure.fetch('message')}"
        end
        attempt = checkpoint["in_flight"]
        return unless attempt

        raise AmbiguousDeliveryError,
              "hive digest: delivery is parked because Telegram outcome for chunk " \
              "#{attempt.fetch('chunk_index') + 1}/#{checkpoint.fetch('total_chunks')} is unknown"
      end

      # Send only the suffix beginning at the durable next_chunk cursor.
      # Persist an in-flight state before each non-idempotent Telegram call,
      # then atomically accept it. A restart never blindly replays an outcome
      # that might already have reached Telegram.
      def send_in_chunks(client, chat_id, checkpoint)
        responses = []
        while checkpoint.fetch("next_chunk") < checkpoint.fetch("total_chunks")
          checkpoint, accepted = deliver_checkpoint_chunk(client, chat_id, checkpoint)
          responses.concat(accepted)
        end
        responses
      end

      def deliver_checkpoint_chunk(client, chat_id, checkpoint)
        idx = checkpoint.fetch("next_chunk")
        total = checkpoint.fetch("total_chunks")
        unit = pending_unit(checkpoint, idx)
        checkpoint = @checkpoint_store.begin_attempt(
          checkpoint,
          chunk_index: idx,
          payload: unit.fetch(:payload),
          parse_mode: unit.fetch(:parse_mode)
        )
        response = send_exact_message(
          client,
          chat_id: chat_id,
          text: unit.fetch(:payload),
          parse_mode: unit.fetch(:parse_mode)
        )
        checkpoint = accept_response!(checkpoint, next_chunk: idx + 1)
        [ checkpoint, normalize_responses(response) ]
      rescue ::Telegram::Bot::Exceptions::ResponseError => e
        handle_telegram_rejection(
          client, chat_id, checkpoint, unit, e,
          accepted_chunks: idx, total_chunks: total
        )
      rescue DeliveryCheckpointError
        # begin_attempt is the only retryable checkpoint transition here; it
        # happens before Telegram I/O. accept_response! wraps its post-send
        # write failure as AmbiguousDeliveryError.
        raise
      rescue PermanentDeliveryError
        raise
      rescue StandardError => e
        record_send_failure(
          e,
          accepted_chunks: idx,
          total_chunks: total,
          recovered: false,
          ambiguous_outcome: true
        )
        raise_ambiguous_outcome!(checkpoint, e, idx, total)
      end

      def handle_telegram_rejection(client, chat_id, checkpoint, unit, error,
                                    accepted_chunks:, total_chunks:)
        if unit.fetch(:parse_mode) == :markdown_v2 && telegram_parse_error?(error)
          return deliver_html_fallback(
            client, chat_id, checkpoint, unit.fetch(:payload), error,
            accepted_chunks: accepted_chunks,
            total_chunks: total_chunks
          )
        end

        if permanent_telegram_response_error?(error)
          record_send_failure(
            error,
            accepted_chunks: accepted_chunks,
            total_chunks: total_chunks,
            recovered: false
          )
          raise_permanent_response!(
            checkpoint, error, accepted_chunks, total_chunks
          )
        end

        checkpoint = reject_attempt!(checkpoint)
        record_send_failure(
          error,
          accepted_chunks: accepted_chunks,
          total_chunks: total_chunks
        )
        raise error
      end

      def deliver_html_fallback(client, chat_id, checkpoint, markdown, original_error,
                                accepted_chunks:, total_chunks:)
        unless client.respond_to?(:markdown_v2_to_html)
          record_send_failure(
            original_error,
            accepted_chunks: accepted_chunks,
            total_chunks: total_chunks,
            recovered: false
          )
          raise_permanent_response!(
            checkpoint, original_error, accepted_chunks, total_chunks
          )
        end

        html = client.markdown_v2_to_html(markdown)
        checkpoint = prepare_fallback!(
          checkpoint, chunk_index: accepted_chunks, payload: html
        )
        checkpoint = @checkpoint_store.begin_attempt(
          checkpoint,
          chunk_index: accepted_chunks,
          payload: html,
          parse_mode: :html
        )
        response = send_exact_message(
          client, chat_id: chat_id, text: html, parse_mode: :html
        )
        checkpoint = accept_response!(checkpoint, next_chunk: accepted_chunks + 1)
        record_send_failure(
          original_error,
          accepted_chunks: accepted_chunks,
          total_chunks: total_chunks,
          fallback_parse_mode: "html",
          recovered: true
        )
        [ checkpoint, normalize_responses(response) ]
      rescue DeliveryCheckpointError
        raise
      rescue PermanentDeliveryError
        raise
      rescue ::Telegram::Bot::Exceptions::ResponseError => fallback_error
        record_send_failure(
          original_error,
          accepted_chunks: accepted_chunks,
          total_chunks: total_chunks,
          fallback_parse_mode: "html",
          fallback_error_class: fallback_error.class.name,
          fallback_error: fallback_error.message,
          recovered: false
        )
        if permanent_telegram_response_error?(fallback_error)
          raise_permanent_response!(
            checkpoint, fallback_error, accepted_chunks, total_chunks
          )
        end
        reject_attempt!(checkpoint)
        raise fallback_error
      rescue Hive::Bot::Telegram::MarkdownV2SplitError => fallback_error
        record_send_failure(
          original_error,
          accepted_chunks: accepted_chunks,
          total_chunks: total_chunks,
          fallback_parse_mode: "html",
          fallback_error_class: fallback_error.class.name,
          fallback_error: fallback_error.message,
          recovered: false
        )
        raise_permanent_response!(
          checkpoint, fallback_error, accepted_chunks, total_chunks
        )
      rescue StandardError => fallback_error
        record_send_failure(
          original_error,
          accepted_chunks: accepted_chunks,
          total_chunks: total_chunks,
          fallback_parse_mode: "html",
          fallback_error_class: fallback_error.class.name,
          fallback_error: fallback_error.message,
          recovered: false,
          ambiguous_outcome: true
        )
        raise_ambiguous_outcome!(
          checkpoint, fallback_error, accepted_chunks, total_chunks
        )
      end

      def accept_response!(checkpoint, next_chunk:)
        @checkpoint_store.accept(checkpoint, next_chunk: next_chunk)
      rescue DeliveryCheckpointError => e
        idx = checkpoint.fetch("next_chunk")
        total = checkpoint.fetch("total_chunks")
        raise_ambiguous_outcome!(checkpoint, e, idx, total)
      end

      def prepare_fallback!(checkpoint, chunk_index:, payload:)
        @checkpoint_store.prepare_fallback(
          checkpoint, chunk_index: chunk_index, payload: payload
        )
      rescue DeliveryCheckpointError => e
        raise PermanentDeliveryCheckpointError,
              "hive digest: cannot persist deterministic HTML fallback: #{e.message}"
      end

      def reject_attempt!(checkpoint)
        @checkpoint_store.reject_attempt(checkpoint)
      rescue DeliveryCheckpointError => e
        raise PermanentDeliveryCheckpointError,
              "hive digest: cannot persist rejected Telegram attempt: #{e.message}"
      end

      def raise_permanent_response!(checkpoint, error, accepted_chunks, total_chunks)
        @checkpoint_store.mark_permanent(
          checkpoint, error: error, outcome_known: true
        )
        raise PermanentDeliveryError,
              "hive digest: Telegram permanently rejected chunk " \
              "#{accepted_chunks + 1}/#{total_chunks}: #{error.message}"
      rescue DeliveryCheckpointError => checkpoint_error
        raise PermanentDeliveryCheckpointError,
              "hive digest: Telegram rejected chunk #{accepted_chunks + 1}/#{total_chunks}, " \
              "but its permanent checkpoint could not be persisted: #{checkpoint_error.message}"
      end

      def raise_ambiguous_outcome!(checkpoint, error, accepted_chunks, total_chunks)
        ambiguous = AmbiguousDeliveryError.new(
          "hive digest: Telegram outcome for chunk " \
          "#{accepted_chunks + 1}/#{total_chunks} is unknown after " \
          "#{error.class}: #{error.message}"
        )
        begin
          @checkpoint_store.mark_permanent(
            checkpoint, error: ambiguous, outcome_known: false
          )
        rescue DeliveryCheckpointError, PermanentDeliveryCheckpointError
          # The persisted in-flight marker is already sufficient to prevent a
          # blind replay. The typed error also parks the daemon date.
        end
        raise ambiguous
      end

      def record_send_failure(error, accepted_chunks:, total_chunks:, **details)
        # Hive::Bot::Logger exposes only #event (closed enum); a plain #error
        # call would mask the real transport failure.
        logger&.event(
          :send_failure,
          context: "digest",
          accepted_chunks: accepted_chunks,
          total_chunks: total_chunks,
          failed_chunk: accepted_chunks + 1,
          error_class: error.class.name,
          error: error.message,
          **details
        )
      end

      def telegram_parse_error?(error)
        return false unless error.is_a?(::Telegram::Bot::Exceptions::ResponseError)

        code, description = telegram_error_details(error)
        code.to_i == 400 && description.match?(/can't parse entities/i)
      rescue JSON::ParserError, KeyError, NoMethodError
        false
      end

      def permanent_telegram_response_error?(error)
        return false unless error.is_a?(::Telegram::Bot::Exceptions::ResponseError)

        code = error.error_code
        (400..499).cover?(code.to_i) && code.to_i != 429
      rescue JSON::ParserError, NoMethodError
        false
      end

      def telegram_error_details(error)
        [ error.error_code, error.data.fetch("description", error.message) ]
      end

      def pending_unit(checkpoint, idx)
        variant = checkpoint["pending_variant"]
        if variant
          {
            payload: variant.fetch("payload"),
            parse_mode: variant.fetch("parse_mode").to_sym
          }
        else
          {
            payload: checkpoint.fetch("chunks").fetch(idx),
            parse_mode: :markdown_v2
          }
        end
      end

      def send_exact_message(client, chat_id:, text:, parse_mode:)
        if client.respond_to?(:send_message_chunk)
          client.send_message_chunk(
            chat_id: chat_id, text: text, parse_mode: parse_mode
          )
        else
          client.send_message(
            chat_id: chat_id, text: text, parse_mode: parse_mode
          )
        end
      end

      def normalize_responses(response)
        response.is_a?(Array) ? response : [ response ]
      end

      def build_telegram(token:, logger:)
        Hive::Bot::Telegram.new(token: token, logger: logger)
      end

      def logger
        @logger ||= Hive::Bot::Logger.new(path: default_log_path)
      end

      def default_log_path
        @cfg.dig("bot", "log_file") || File.join(Hive::Paths.state_home, "logs", "bot.log")
      end
    end
  end
end
