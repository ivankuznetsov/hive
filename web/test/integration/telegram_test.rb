require "test_helper"

class TelegramTest < ActionDispatch::IntegrationTest
  test "the page walks a first-timer through bot setup" do
    sign_in!
    get "/telegram"
    assert_response :success
    assert_select ".setup-guide[open]", 1,
                  "the guide must start expanded while the bot is unconfigured"
    assert_select ".setup-guide a[href='https://t.me/BotFather']", 1
    assert_select ".setup-guide a[href='https://t.me/userinfobot']", 1
    assert_select ".setup-steps li", 3, "three steps: create, chat id, say hello"
  end

  test "blank chat IDs are a 422 before anything is saved or sent to Telegram" do
    sign_in!
    post "/telegram", params: { token: "123:abc", chat_ids: "  " }

    assert_response :unprocessable_entity
    assert_match "At least one numeric chat ID", response.body
    refute Hive::Config.load_global_bot["enabled"],
           "a rejected submit must not flip bot.enabled"
  end

  test "a @handle chat ID is a readable 422, not a silent 0 in the allowlist" do
    sign_in!
    post "/telegram", params: { token: "123:abc", chat_ids: "@mychannel" }

    assert_response :unprocessable_entity
    assert_match "@mychannel", response.body
    assert_empty Hive::Config.load_global_bot["chat_id_allowlist"].to_a,
                 "no allowlist may be persisted from invalid input"
  end
end
