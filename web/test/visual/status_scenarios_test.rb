require "application_system_test_case"
require_relative "../support/ui_fixtures"

# Run explicitly to capture both empty and populated Board/Grid at two widths.
# The output includes a ready-to-upload Screenote manifest, but never publishes.
class StatusScenariosTest < ApplicationSystemTestCase
  include UiFixtures

  teardown { StatusBroadcaster.stop! }

  test "capture empty and populated workspaces through real project and task routes" do
    output = Rails.root.join("tmp/ui-captures", Time.now.utc.strftime("%Y%m%dT%H%M%S") + "-#{Process.pid}")
    output.mkpath
    images = []
    sign_in!

    %i[empty populated].each do |scenario|
      tasks = seed_ui_fixture!(scenario)
      refresh_status_feed!
      %w[light dark].each do |theme|
        page.driver.with_playwright_page { |browser| browser.emulate_media(colorScheme: theme) }
        [ [ "desktop", 1280 ], [ "mobile", 375 ] ].each do |viewport, width|
          page.current_window.resize_to(width, 900)
          [ "board", "grid" ].each do |view|
            visit "/#{view}"
            wait_for_status_snapshot
            if scenario == :empty
              assert_text "No projects yet."
              assert_no_selector ".kanban-card, .task-row"
            else
              assert_selector ".project-nav-item", text: "hive-demo", visible: :all
              assert_selector ".project-nav-item", text: "notes-demo", visible: :all
              assert_selector view == "board" ? ".kanban-card" : ".task-row", count: tasks.size
              tasks.each { |task| assert_selector "a", text: task.fetch(:title), visible: :all }
            end
            refute page.evaluate_script("document.documentElement.scrollWidth > innerWidth")
            filename = "#{scenario}-#{view}-#{theme}-#{viewport}.png"
            page.driver.with_playwright_page { |browser| browser.screenshot(path: output.join(filename).to_s, fullPage: true) }
            images << { page: "Hive Web - #{view.titleize} - #{scenario} fixture - #{theme}",
                        title: "#{view.titleize} #{scenario} #{theme} - synthetic UI fixture (local working tree)",
                        file: filename, viewport: }
          end
        end
        # Account/avatar and navigation are visible in the expanded mobile menu.
        click_button "Menu"
        assert_selector ".session-avatar img"
        assert page.evaluate_script("document.querySelector('.session-avatar img').naturalWidth > 0")
        filename = "#{scenario}-menu-#{theme}-mobile.png"
        page.driver.with_playwright_page { |browser| browser.screenshot(path: output.join(filename).to_s, fullPage: true) }
        images << { page: "Hive Web - Menu - #{scenario} fixture - #{theme}",
                    title: "Menu #{scenario} #{theme} - synthetic UI fixture (local working tree)",
                    file: filename, viewport: "mobile" }
      end
      next if tasks.empty?

      task = tasks.first
      visit task_path(task.fetch(:project), task.fetch(:slug))
      assert_selector ".task-header", text: task.fetch(:title)
    end

    commit = IO.popen([ "git", "-C", Rails.root.parent.to_s, "rev-parse", "HEAD" ], &:read).strip
    manifest = { version: 1, git_commit: commit, taken_at: Time.now.utc.iso8601, images: }
    output.join("screenote-manifest.json").write(JSON.pretty_generate(manifest) + "\n")
    output.join("README.txt").write("Synthetic test workspaces; not live operational evidence.\nBase commit: #{commit}; captures include local working-tree changes.\n")
    puts "UI captures: #{output}"
  end
end
