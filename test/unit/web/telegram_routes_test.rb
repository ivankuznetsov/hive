require "test_helper"
require_relative "../../support/web_session_helper"
require "hive/config"
require "hive/env_file"

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
    # EnvFile::DEFAULT_PATH is frozen from config_home at require time, so the
    # token-wizard routes read/write a single shared .env regardless of the
    # per-test HIVE_HOME. Snapshot and restore it around every test so neither
    # a sibling test nor the developer's real .env leaks into (or out of) the
    # token-presence assertions below.
    path = Hive::EnvFile::DEFAULT_PATH
    saved = File.exist?(path) ? File.read(path) : nil
    FileUtils.rm_f(path)
    with_tmp_global_config do |home|
      boot_web_app
      login!
      yield(home)
    end
  ensure
    FileUtils.rm_f(path)
    if saved
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, saved)
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

  # /telegram/test must refuse to send when no token has been saved yet (neither
  # in ENV nor the .env file): the round-trip would otherwise call Telegram with
  # an empty token. The guard re-renders the form with an inline error (no JS).
  # The .env file exists but holds no token key, so read_env_value scans it and
  # returns nil (its no-match path) before the empty-token guard fires.
  def test_test_message_without_saved_token_is_rejected
    with_box do |_home|
      FileUtils.mkdir_p(File.dirname(Hive::EnvFile::DEFAULT_PATH))
      File.write(Hive::EnvFile::DEFAULT_PATH, "UNRELATED_KEY=value\n")

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => nil) do
        token = csrf_token_from("/telegram")

        post "/telegram/test", { "authenticity_token" => token }, "HTTP_HOST" => "127.0.0.1"

        assert_equal 422, last_response.status, "no saved token must block the test send"
        assert_includes last_response.body, "Save a bot token before sending a test message."
      end
    end
  end

  # When the token is absent from the live ENV but present in the .env file the
  # wizard wrote, saved_telegram_token must fall back to read_env_value and
  # still drive the round-trip (the web process may not have it exported).
  def test_test_message_reads_token_from_env_file_fallback
    with_box do |_home|
      FileUtils.mkdir_p(File.dirname(Hive::EnvFile::DEFAULT_PATH))
      # An unrelated earlier line plus the real key, so read_env_value scans
      # past a non-match before returning the token from the file.
      File.write(Hive::EnvFile::DEFAULT_PATH, "SOMETHING_ELSE=x\nHIVE_TELEGRAM_BOT_TOKEN=\"999:fromfile\"\n")
      @app.set :telegram_tester, FixedTester.new({ ok: true, sent: 1 })

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => nil) do
        token = csrf_token_from("/telegram")

        post "/telegram/test", { "authenticity_token" => token }, "HTTP_HOST" => "127.0.0.1"

        assert last_response.ok?, "a token read from the .env file must drive the round-trip"
        assert_includes last_response.body, "Sent a test message"
      end
    end
  end

  # Saving a token twice must rewrite the existing HIVE_TELEGRAM_BOT_TOKEN line
  # in place (the write_env_value replace branch), not append a duplicate.
  def test_saving_token_twice_rewrites_env_line_in_place
    with_box do |_home|
      @app.set :telegram_validator, FixedValidator.new(true)
      # Seed an unrelated key so the in-place rewrite has a NON-matching line to
      # preserve (write_env_value's else branch) as well as the token line to
      # replace.
      FileUtils.mkdir_p(File.dirname(Hive::EnvFile::DEFAULT_PATH))
      File.write(Hive::EnvFile::DEFAULT_PATH, "KEEP_ME=untouched\n")

      token = csrf_token_from("/telegram")
      post "/telegram",
           { "token" => "111:first", "chat_ids" => "1", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      token = csrf_token_from("/telegram")
      post "/telegram",
           { "token" => "222:second", "chat_ids" => "2", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      env_body = File.read(Hive::EnvFile::DEFAULT_PATH)
      assert_includes env_body, "HIVE_TELEGRAM_BOT_TOKEN=222:second"
      assert_includes env_body, "KEEP_ME=untouched", "an unrelated env line must be preserved across the rewrite"
      assert_equal 1, env_body.scan("HIVE_TELEGRAM_BOT_TOKEN=").length,
                   "a second save must rewrite the line in place, not duplicate it"
    end
  end

  # request_bot_restart signals the container supervisor on save. A stale
  # (already-exited) pid makes Process.kill raise ESRCH; the rescue must absorb
  # it so a dead supervisor pid can't crash the token save.
  def test_save_tolerates_a_stale_supervisor_pid
    with_box do |_home|
      @app.set :telegram_validator, FixedValidator.new(true)

      # A reaped child's pid is guaranteed dead, so HUP to it raises ESRCH.
      dead_pid = spawn("true")
      Process.wait(dead_pid)

      with_env("HIVEBOX_SUPERVISOR_PID" => dead_pid.to_s) do
        token = csrf_token_from("/telegram")
        post "/telegram",
             { "token" => "333:tok", "chat_ids" => "3", "authenticity_token" => token },
             "HTTP_HOST" => "127.0.0.1"

        assert last_response.redirect?, "a stale supervisor pid must not break the save"
      end
    end
  end
end
