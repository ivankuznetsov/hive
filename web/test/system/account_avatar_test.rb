require "application_system_test_case"

class AccountAvatarTest < ApplicationSystemTestCase
  teardown { StatusBroadcaster.stop! }

  test "GitHub avatar loads beside the account and falls back to an initial on failure" do
    sign_in!
    assert_selector ".session-avatar img[src='https://github.com/alice.png?size=64']"
    assert page.evaluate_script("document.querySelector('.session-avatar img').naturalWidth > 0")

    page.driver.with_playwright_page do |browser|
      browser.route("https://github.com/*.png?size=64", ->(route, _request) { route.abort })
    end
    visit grid_path
    assert_selector ".session-avatar", text: "A"
    assert_no_selector ".session-avatar img"
    assert_selector ".session-login", text: "alice"
  end
end
