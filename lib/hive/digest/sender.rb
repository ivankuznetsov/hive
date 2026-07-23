require "hive/bot/logger"
require "hive/bot/telegram"
require "hive/config"
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

      def initialize(cfg:, telegram_factory: nil, logger: nil, redactor: Hive::SecretPatterns)
        @cfg = cfg || {}
        @telegram_factory = telegram_factory || method(:build_telegram)
        @logger = logger
        @redactor = redactor
      end

      # Resolve the recipient + token without sending, so callers can fail
      # fast before an expensive changelog-generator run. Raises Hive::ConfigError
      # when either is missing.
      def preflight!
        self.class.resolve_chat_id(@cfg)
        Hive::Config.telegram_bot_token!
        nil
      end

      def deliver(text, dry_run: false)
        return SendResult.new(chat_id: nil, responses: [], dry_run: true, text: text) if dry_run

        text = safe_delivery_text(text)
        chat_id = self.class.resolve_chat_id(@cfg)
        client = @telegram_factory.call(token: Hive::Config.telegram_bot_token!, logger: logger)
        responses = send_in_chunks(client, chat_id, text)
        SendResult.new(chat_id: chat_id, responses: responses, dry_run: false, text: text)
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

      # Send the digest one Telegram chunk at a time so a mid-stream
      # failure logs exactly how many chunks Telegram already accepted.
      # On a mid-stream failure we do NOT resend the already-accepted
      # chunks within this invocation, then re-raise. The subprocess exits
      # non-zero and the daemon's DigestScheduler re-owes and re-dispatches
      # the whole date on a later tick — once the failure backoff expires
      # (in-process) or after a restart — so delivery is at-least-once across
      # retries (a rare multi-chunk mid-stream failure can duplicate the
      # earlier chunks), which is the plan's accepted recovery model;
      # cross-process chunk de-duplication would be out of proportion to
      # that failure mode.
      def send_in_chunks(client, chat_id, text)
        chunks = client.respond_to?(:message_chunks) ? client.message_chunks(text) : [ text ]
        responses = []
        chunks.each_with_index do |chunk, idx|
          responses.concat(
            Array(client.send_message(chat_id: chat_id, text: chunk, parse_mode: :markdown_v2))
          )
        rescue StandardError => e
          # Hive::Bot::Logger exposes only #event (closed enum); a plain
          # #error call would raise NoMethodError and mask the real send
          # failure. Record the partial-delivery context as a structured
          # :send_failure event instead.
          logger&.event(
            :send_failure,
            context: "digest",
            accepted_chunks: idx,
            total_chunks: chunks.size,
            failed_chunk: idx + 1,
            error_class: e.class.name,
            error: e.message
          )
          raise
        end
        responses
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
