require "application_system_test_case"

class KanbanBoardTest < ApplicationSystemTestCase
  setup { StatusBroadcaster.start! }
  teardown { StatusBroadcaster.stop! }

  test "operator switches between the live board and grid without losing the preference" do
    project = create_hive_project!("kanban-browser-app")
    slug = create_task!(project, "Move through a native board")
    visit dev_login_path(as: "alice")

    assert_selector "#status-board"
    assert_selector ".kanban-card", text: "Move through a native board"

    execute_script(<<~JS)
      document.addEventListener("submit", () => {
        const stream = document.createElement("turbo-stream")
        stream.setAttribute("action", "refresh")
        document.documentElement.appendChild(stream)
      }, { once: true })
      document.addEventListener("turbo:submit-start", () => {
        const stream = document.createElement("turbo-stream")
        stream.setAttribute("action", "refresh")
        document.documentElement.appendChild(stream)
      }, { once: true })
      document.addEventListener("turbo:submit-end", () => {
        const stream = document.createElement("turbo-stream")
        stream.setAttribute("action", "refresh")
        document.documentElement.appendChild(stream)
      }, { once: true })
    JS
    click_button "Grid"
    assert_current_path grid_path, wait: 10
    assert_selector "#status-grid .task-row", text: slug

    visit root_path
    assert_selector "#status-grid", wait: 5

    click_button "Board"
    assert_current_path board_path
    assert_selector "#status-board .kanban-card", text: slug
  end

  test "board remains contained at a mobile viewport" do
    project = create_hive_project!("kanban-#{"unbroken" * 8}")
    create_task!(project, "A deliberately long kanban task title that must stay inside the mobile viewport")
    visit dev_login_path(as: "alice")
    page.current_window.resize_to(375, 812)

    assert_selector "#status-board"
    metrics = page.evaluate_script(<<~JS)
      (() => {
        const columns = document.querySelector(".kanban-columns")
        columns.scrollLeft = 120
        return {
          viewport: document.documentElement.clientWidth,
          documentWidth: document.documentElement.scrollWidth,
          boardWidth: document.querySelector("#status-board").scrollWidth,
          columnsClientWidth: columns.clientWidth,
          columnsScrollWidth: columns.scrollWidth,
          columnsScrollLeft: columns.scrollLeft
        }
      })()
    JS
    assert_operator metrics.fetch("documentWidth"), :<=, metrics.fetch("viewport") + 1
    assert_operator metrics.fetch("boardWidth"), :>=, metrics.fetch("viewport") - 30,
                    "the columns should scroll inside the board rather than widening the page"
    assert_operator metrics.fetch("columnsScrollWidth"), :>, metrics.fetch("columnsClientWidth")
    assert_operator metrics.fetch("columnsScrollLeft"), :>, 0
  end

  test "project filter survives a view switch" do
    selected_project = create_hive_project!("kanban-filtered-app")
    hidden_project = create_hive_project!("kanban-hidden-app")
    create_task!(selected_project, "Keep this project selected")
    create_task!(hidden_project, "Hide this other project")
    visit dev_login_path(as: "alice")

    click_button selected_project
    assert_selector ".kanban-band[data-project-name='#{selected_project}']"
    assert_selector ".kanban-band[data-project-name='#{hidden_project}']", visible: :hidden

    click_button "Grid"

    assert_current_path grid_path(project: selected_project)
    assert_selector "#status-grid .project-section[data-project-name='#{selected_project}']"
    assert_selector "#status-grid .project-section[data-project-name='#{hidden_project}']", visible: :hidden
  end

  test "a refresh deferred during a failed idea submission is replayed" do
    project = create_hive_project!("kanban-refresh-replay-app")
    visit dev_login_path(as: "alice")

    execute_script(<<~JS)
      document.querySelector("#composer").dispatchEvent(new CustomEvent("turbo:submit-start", {
        bubbles: true
      }))
    JS
    slug = create_task!(project, "Visible after failed submit")
    execute_script(<<~JS)
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "refresh")
      document.documentElement.appendChild(stream)
    JS
    assert_no_selector ".kanban-card[data-task-slug='#{slug}']", wait: 0

    execute_script(<<~JS)
      document.querySelector("#composer").dispatchEvent(new CustomEvent("turbo:submit-end", {
        bubbles: true,
        detail: { success: false, fetchResponse: { statusCode: 422 } }
      }))
    JS

    assert_selector ".kanban-card[data-task-slug='#{slug}']", wait: 10
  end

  test "live project reordering preserves the focused card and band scroll" do
    focused_project = create_hive_project!("kanban-focused-app")
    moving_project = create_hive_project!("kanban-moving-app")
    focused_slug = create_task!(focused_project, "Keep this action focused")
    disable_daemon!(focused_project)
    visit dev_login_path(as: "alice")

    focused_card = find(".kanban-card[data-task-slug='#{focused_slug}']")
    focused_card.find_button("Run brainstorm")
    expected_action = evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".kanban-card[data-task-slug='#{focused_slug}']")
        card.querySelector("button").focus()
        return card.querySelector("form").action
      })()
    JS
    initial_scroll = evaluate_script(<<~JS)
      (() => {
        const columns = document.querySelector(".kanban-band[data-project-name='#{focused_project}'] .kanban-columns")
        columns.scrollLeft = 120
        return columns.scrollLeft
      })()
    JS
    assert_operator initial_scroll, :>, 0

    create_task!(moving_project, "Move ahead one")
    create_task!(moving_project, "Move ahead two")
    assert_selector ".kanban-band[data-project-name='#{moving_project}'] .kanban-card", count: 2, wait: 10
    project_order = evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#status-board > .kanban-band"))
        .map((band) => band.dataset.projectName)
    JS
    assert_operator project_order.index(moving_project), :<, project_order.index(focused_project)

    assert_equal expected_action, evaluate_script("document.activeElement.closest('form')?.action")
    final_scroll = evaluate_script(
      "document.querySelector(\".kanban-band[data-project-name='#{focused_project}'] .kanban-columns\").scrollLeft"
    )
    assert_operator final_scroll, :>=, initial_scroll - 1
  end

  test "a focused task follows its card when the live workflow stage changes" do
    project = create_hive_project!("kanban-focused-move-app")
    slug = create_task!(project, "Follow this moving card")
    visit dev_login_path(as: "alice")
    expected_href = evaluate_script(<<~JS)
      (() => {
        const link = document.querySelector(".kanban-card[data-task-slug='#{slug}'] a")
        link.focus()
        return link.href
      })()
    JS

    FileUtils.mv(stage_dir(project, "1-inbox").join(slug), stage_dir(project, "2-brainstorm").join(slug))
    assert_selector ".kanban-column[data-stage='2-brainstorm'] .kanban-card[data-task-slug='#{slug}']", wait: 10

    assert_equal slug, evaluate_script("document.activeElement.closest('.kanban-card')?.dataset.taskSlug")
    assert_equal expected_href, evaluate_script("document.activeElement.href")
  end

  test "a live refresh cannot abort a board task action" do
    project = create_hive_project!("kanban-action-race-app")
    slug = create_task!(project, "Queue this exactly once")
    disable_daemon!(project)
    visit dev_login_path(as: "alice")
    dispatches = Queue.new
    replacement = lambda do |**attributes|
      dispatches << attributes
      Hive::Bot::DispatchRequestWriter::DispatchReference.new(
        request_id: "system-test-request", attempt_id: nil, state: "queued",
        status: :queued, argv: attributes.fetch(:argv)
      )
    end

    execute_script(<<~JS)
      document.addEventListener("turbo:submit-start", () => {
        const stream = document.createElement("turbo-stream")
        stream.setAttribute("action", "refresh")
        document.documentElement.appendChild(stream)
      }, { once: true })
    JS
    with_replaced_singleton_method(Hive::Bot::DispatchRequestWriter, :dispatch!, replacement) do
      within(".kanban-card[data-task-slug='#{slug}']") { click_button "Run brainstorm" }
      assert_selector ".flash-notice", text: "Queued for the daemon", wait: 10
    end
    assert_equal 1, dispatches.size
    assert_equal slug, dispatches.pop.fetch(:slug)
  end

  test "a Cable reconnect catches up after a missed status broadcast" do
    project = create_hive_project!("kanban-cable-reconnect-app")
    visit dev_login_path(as: "alice")
    assert_selector "turbo-cable-stream-source[connected]", visible: :all, wait: 10

    execute_script(<<~JS)
      window.testStatusLayout = document.querySelector("[data-controller~='status-refresh']")
      window.testStatusLayout.remove()
    JS
    slug = create_task!(project, "Visible after reconnect")

    execute_script(<<~JS)
      document.body.appendChild(window.testStatusLayout)
    JS

    assert_selector "turbo-cable-stream-source[connected]", visible: :all, wait: 10
    assert_selector ".kanban-card[data-task-slug='#{slug}']", wait: 10
  end

  test "a restored Board catches up after its cached Cable source reconnects" do
    project = create_hive_project!("kanban-history-reconnect-app")
    original_slug = create_task!(project, "Open this before history restore")
    visit dev_login_path(as: "alice")
    assert_selector "turbo-cable-stream-source[connected]", visible: :all, wait: 10

    find(".kanban-card[data-task-slug='#{original_slug}'] a").click
    assert_current_path task_path(project, original_slug)
    restored_slug = create_task!(project, "Visible after history restore")

    page.go_back

    assert_selector "turbo-cable-stream-source[connected]", visible: :all, wait: 10
    assert_selector ".kanban-card[data-task-slug='#{restored_slug}']", wait: 10
  end

  private

  def disable_daemon!(project)
    path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project, ".hive-state", "config.yml")
    data = YAML.safe_load_file(path) || {}
    data["daemon"] = (data["daemon"] || {}).merge("enabled" => false)
    File.write(path, data.to_yaml)
  end
end
