require "test_helper"
require_relative "../../support/web_session_helper"
require "hive/config"

# U6: the Telegram wizard must validate the token against the real Telegram
# API (getMe) BEFORE persisting. The route delegates validation to an
# injectable `telegram_validator` so this test drives the accept/reject
# branches without a network round-trip while keeping the production default
# pointed at the real API.
class WebTelegramRoutesTest < Minitest::Test
  include HiveTestHelper
  include WebSessionHelper

  # A non-Proc callable: Sinatra's `set` invokes a Proc value lazily to
  # compute the setting, so a stub validator must be a plain object that
  # responds to #call instead of a lambda.
  FixedValidator = Struct.new(:result) do
    def call(_token) = result
  end

  def with_box
    with_tmp_global_config do |home|
      boot_web_app
      login!
      yield(home)
    end
  end

  def test_invalid_token_persists_nothing
    with_box do |_home|
      @app.set :telegram_validator, FixedValidator.new(false)
      token = csrf_token_from("/telegram")

      post "/telegram",
           { "token" => "bogus", "chat_ids" => "123", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 422, last_response.status, "invalid token must be rejected"
      assert_includes last_response.body, "Nothing was saved"
      refute Hive::Config.load_global_bot["enabled"], "bot must NOT be enabled on a rejected token"
    end
  end

  def test_valid_token_persists_and_enables_bot
    with_box do |_home|
      @app.set :telegram_validator, FixedValidator.new(true)
      token = csrf_token_from("/telegram")

      post "/telegram",
           { "token" => "123:goodtoken", "chat_ids" => "42, 99", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?, "a valid token should save and redirect"
      bot = Hive::Config.load_global_bot
      assert bot["enabled"], "valid token must enable the bot"
      assert_equal [ 42, 99 ], bot["chat_id_allowlist"]
      assert_includes File.read(Hive::EnvFile::DEFAULT_PATH), "HIVE_TELEGRAM_BOT_TOKEN=123:goodtoken"
    end
  end

  def test_empty_token_is_rejected
    with_box do |_home|
      token = csrf_token_from("/telegram")

      post "/telegram",
           { "token" => "", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 422, last_response.status
    end
  end

  # A non-Proc stub for the injectable round-trip tester (see FixedValidator).
  FixedTester = Struct.new(:result) do
    def call(token:, chat_ids:) = result
  end

  def test_test_message_round_trip_reports_success
    with_box do |_home|
      @app.set :telegram_tester, FixedTester.new({ ok: true, sent: 2 })
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "123:tok") do
        token = csrf_token_from("/telegram")

        post "/telegram/test", { "authenticity_token" => token }, "HTTP_HOST" => "127.0.0.1"

        assert last_response.ok?, "a successful round-trip re-renders 200"
        assert_includes last_response.body, "Sent a test message"
      end
    end
  end

  def test_test_message_failure_is_surfaced_inline
    with_box do |_home|
      @app.set :telegram_tester, FixedTester.new({ ok: false, error: "getMe failed" })
      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "123:tok") do
        token = csrf_token_from("/telegram")

        post "/telegram/test", { "authenticity_token" => token }, "HTTP_HOST" => "127.0.0.1"

        assert_equal 422, last_response.status
        assert_includes last_response.body, "Telegram test failed"
      end
    end
  end
end
