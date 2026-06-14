require "hive/bot/logger"
require "hive/bot/telegram"
require "hive/config"
require "hive/paths"

module Hive
  module Digest
    class Sender
      SendResult = Data.define(:chat_id, :responses, :dry_run, :text)

      def initialize(cfg:, telegram_factory: nil, logger: nil)
        @cfg = cfg || {}
        @telegram_factory = telegram_factory || method(:build_telegram)
        @logger = logger
      end

      def deliver(text, dry_run: false)
        return SendResult.new(chat_id: nil, responses: [], dry_run: true, text: text) if dry_run

        chat_id = self.class.resolve_chat_id(@cfg)
        responses = @telegram_factory.call(token: Hive::Config.telegram_bot_token!, logger: logger)
                                     .send_message(chat_id: chat_id, text: text, parse_mode: :markdown_v2)
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
