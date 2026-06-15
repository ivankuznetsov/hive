require "hive/bot/logger"
require "hive/bot/telegram"
require "hive/config"
require "hive/paths"

module Hive
  module Digest
    class Sender
      SendResult = Data.define(:chat_id, :responses, :dry_run, :text) do
        # A dry-run never resolves a recipient, so carrying a chat_id on a
        # dry-run result is a contradiction — guard it at the boundary.
        def initialize(chat_id:, responses:, dry_run:, text:)
          raise ArgumentError, "dry-run digest send result must not carry a chat_id" if dry_run && !chat_id.nil?

          super
        end
      end

      def initialize(cfg:, telegram_factory: nil, logger: nil)
        @cfg = cfg || {}
        @telegram_factory = telegram_factory || method(:build_telegram)
        @logger = logger
      end

      # Resolve the recipient + token without sending, so callers can fail
      # fast before an expensive categorizer run. Raises Hive::ConfigError
      # when either is missing.
      def preflight!
        self.class.resolve_chat_id(@cfg)
        Hive::Config.telegram_bot_token!
        nil
      end

      def deliver(text, dry_run: false)
        return SendResult.new(chat_id: nil, responses: [], dry_run: true, text: text) if dry_run

        chat_id = self.class.resolve_chat_id(@cfg)
        client = @telegram_factory.call(token: Hive::Config.telegram_bot_token!, logger: logger)
        responses = send_in_chunks(client, chat_id, text)
        SendResult.new(chat_id: chat_id, responses: responses, dry_run: false, text: text)
      end

      def self.resolve_chat_id(cfg)
        bot = cfg.fetch("bot", {})
        digest_chat_id = bot["digest_chat_id"]
        return digest_chat_id unless blank?(digest_chat_id)

        chat_id = Array(bot["chat_id_allowlist"]).first
        return chat_id unless blank?(chat_id)

        raise Hive::ConfigError,
              "bot.digest_chat_id or bot.chat_id_allowlist[0] must be configured before sending digest"
      end

      def self.blank?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      private

      # Send the digest one Telegram chunk at a time so a mid-stream
      # failure logs exactly how many chunks Telegram already accepted.
      # That partial-delivery signal lets an operator avoid blindly
      # re-sending a digest whose earlier chunks already landed (a plain
      # full resend would duplicate them).
      def send_in_chunks(client, chat_id, text)
        chunks = client.respond_to?(:message_chunks) ? client.message_chunks(text) : [ text ]
        responses = []
        chunks.each_with_index do |chunk, idx|
          responses.concat(
            Array(client.send_message(chat_id: chat_id, text: chunk, parse_mode: :markdown_v2))
          )
        rescue StandardError => e
          logger&.error(
            "digest sender: partial delivery — #{idx} of #{chunks.size} chunk(s) accepted " \
            "before chunk #{idx + 1} failed (#{e.class}: #{e.message}); not auto-resending accepted chunks"
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
