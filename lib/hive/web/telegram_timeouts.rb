require "telegram/bot"
require "faraday"

module Hive
  module Web
    # Shared Telegram transport policy for the web UI's validator/tester.
    #
    # The telegram-bot gem reads its Faraday connect/read timeouts from a
    # process-global configuration that defaults to 20s each. A slow or
    # unreachable Telegram would otherwise block a Sinatra request thread for
    # ~20s and then raise a Faraday/Socket error the routes never rescued —
    # producing an opaque blank 500. We clamp the timeouts to a short window so
    # a failure surfaces fast, and the validator/tester rescue NETWORK_ERRORS
    # to convert them into a friendly Hive::Error.
    module TelegramTimeouts
      CONNECT_TIMEOUT_SEC = 8
      READ_TIMEOUT_SEC = 8

      # Transport-level failures that escape the gem's own ResponseError. A bare
      # SocketError can surface when DNS fails before Faraday wraps it.
      NETWORK_ERRORS = [
        Faraday::TimeoutError,
        Faraday::ConnectionFailed,
        SocketError
      ].freeze

      module_function

      # Apply the short timeouts to the gem's global configuration. Idempotent;
      # called at load time by the validator/tester.
      def apply!
        ::Telegram::Bot.configure do |config|
          config.connection_open_timeout = CONNECT_TIMEOUT_SEC
          config.connection_timeout = READ_TIMEOUT_SEC
        end
      end
    end
  end
end

Hive::Web::TelegramTimeouts.apply!
