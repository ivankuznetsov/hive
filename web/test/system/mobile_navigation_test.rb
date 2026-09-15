require "application_system_test_case"
require_relative "../support/ui_fixtures"

class MobileNavigationTest < ApplicationSystemTestCase
  include UiFixtures
  teardown { StatusBroadcaster.stop! }

  test "phone navigation opens with a hamburger and closes with Escape or a page visit" do
    seed_ui_fixture!(:populated)
    sign_in!
    page.current_window.resize_to(375, 812)
    visit root_path

    assert_button "Menu"
    assert_selector ".brand img[src='/brand.svg']"
    assert page.evaluate_script("document.querySelector('.brand img').naturalWidth > 0")
    assert_selector ".brand", text: "Hive", exact_text: true
    assert_selector "#mobile-project-filter option:checked", text: "All projects"
    controls = page.evaluate_script(<<~JS)
      (() => {
        const select = document.querySelector('#mobile-project-filter').getBoundingClientRect();
        const add = document.querySelector('.project-nav-mobile .project-nav-add').getBoundingClientRect();
        return { selectRight: select.right, addLeft: add.left, addRight: add.right, width: innerWidth };
      })()
    JS
    assert_operator controls.fetch("selectRight"), :<=, controls.fetch("addLeft")
    assert_operator controls.fetch("addRight"), :<=, controls.fetch("width")
    assert_no_selector "nav[aria-label='Primary']"
    assert_no_button "Log out"
    assert_operator page.evaluate_script("document.querySelector('.topbar').getBoundingClientRect().height"), :<, 80

    click_button "Menu"
    assert_selector "button[aria-label='Menu'][aria-expanded='true']"
    within "nav[aria-label='Primary']" do
      %w[Status Digest Repos Honeycombs Patrol Agents Telegram].each { |label| assert_link label }
    end
    assert_button "Log out"
    alignment = page.evaluate_script(<<~JS)
      (() => {
        const link = document.querySelector('.topbar .nav-link');
        const textLeft = link.getBoundingClientRect().left + parseFloat(getComputedStyle(link).paddingLeft);
        return { textLeft, profileLeft: document.querySelector('.session-identity').getBoundingClientRect().left };
      })()
    JS
    assert_in_delta alignment.fetch("textLeft"), alignment.fetch("profileLeft"), 1
    refute page.evaluate_script("document.documentElement.scrollWidth > innerWidth")

    find("button[aria-label='Menu']").send_keys(:escape)
    assert_no_selector "nav[aria-label='Primary']"
    assert_equal "Menu", page.evaluate_script("document.activeElement.getAttribute('aria-label')")

    click_button "Menu"
    within("nav[aria-label='Primary']") { click_link "Repos" }
    assert_current_path repos_path
    assert_no_selector "nav[aria-label='Primary']"
    click_button "Menu"
    assert_selector "nav a.nav-link-active", text: "Repos"

    page.current_window.resize_to(1280, 812)
    assert_no_button "Menu"
    assert_selector "nav[aria-label='Primary']"
    assert_button "Log out"
  end
  test "mobile project dropdown preserves route queries and the composer draft" do
    seed_ui_fixture!(:populated)
    sign_in!
    page.current_window.resize_to(375, 812)

    %w[board grid archive].each do |view|
      visit "/#{view}?display=detailed"
      fill_in "New idea", with: "Keep this draft" unless view == "archive"
      select "hive-demo", from: "Filter projects"
      assert_current_path "/#{view}?display=detailed&project=hive-demo"
      assert_selector ".project-section[data-project-name='hive-demo']"
      assert_no_selector ".project-section[data-project-name='notes-demo']"
      unless view == "archive"
        assert_field "New idea", with: "Keep this draft"
        assert_equal "hive-demo", find("#composer select[name=project]").value
      end
      select "All projects", from: "Filter projects"
      assert_current_path "/#{view}?display=detailed"
    end
  end
end
