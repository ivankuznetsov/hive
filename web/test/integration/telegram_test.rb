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
end
