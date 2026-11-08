require "application_system_test_case"

class StatusLoadingTest < ApplicationSystemTestCase
  test "loading and failed refreshes keep the project rail beside the main content" do
    configure_owner!
    original_snapshot = StatusBroadcaster.method(:snapshot_with_version)
    snapshot = StatusBroadcaster::PageSnapshot.new(
      payload: Hive::Web::StatusFeed::UNAVAILABLE_PAYLOAD,
      version: StatusBroadcaster::LOADING_VERSION, availability: "unavailable"
    )
    StatusBroadcaster.define_singleton_method(:snapshot_with_version) { snapshot }
    visit "/dev_login?as=alice"

    [ "loading", "unavailable", "degraded" ].each do |state|
      snapshot.version = state == "loading" ? StatusBroadcaster::LOADING_VERSION : "failed-token"
      snapshot.availability = state == "degraded" ? "degraded" : "unavailable"
      snapshot.error = state == "loading" ? nil : "Status refresh failed"
      [ 1280, 375 ].each do |width|
        page.current_window.resize_to(width, 812)
        [ board_path, grid_path ].each do |path|
          visit path
          assert_selector state == "loading" ? ".status-loading" : ".status-freshness-warning"
          metrics = page.evaluate_script(<<~JS)
            (() => {
              const rail = document.querySelector('.project-nav').getBoundingClientRect();
              const main = document.querySelector('.status-main').getBoundingClientRect();
              return { railRight: rail.right, railBottom: rail.bottom, mainLeft: main.left,
                       mainTop: main.top, mainWidth: main.width,
                       overflow: document.documentElement.scrollWidth > innerWidth };
            })()
          JS
          refute metrics.fetch("overflow"), "#{state} #{path} overflows at #{width}px"
          if width > 760
            assert_operator metrics.fetch("mainLeft"), :>=, metrics.fetch("railRight")
            assert_operator metrics.fetch("mainWidth"), :>, 700
          else
            assert_operator metrics.fetch("mainTop"), :>=, metrics.fetch("railBottom")
            assert_operator metrics.fetch("mainWidth"), :>, 300
          end
          if width <= 760 && state == "loading"
            loading = page.evaluate_script(<<~JS)
              (() => {
                const panel = document.querySelector('.status-loading').getBoundingClientRect();
                const composer = document.querySelector('.composer').getBoundingClientRect();
                return { bottom: panel.bottom, height: panel.height, composerTop: composer.top };
              })()
            JS
            assert_operator loading.fetch("bottom"), :<, 400,
                            "the loading message should be visible immediately on a phone"
            assert_operator loading.fetch("height"), :<, 120
            assert_operator loading.fetch("bottom"), :<=, loading.fetch("composerTop")
          end
        end
      end
    end
  ensure
    StatusBroadcaster.define_singleton_method(:snapshot_with_version, original_snapshot) if original_snapshot
    StatusBroadcaster.stop!
  end
end
