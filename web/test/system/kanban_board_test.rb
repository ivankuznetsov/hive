require "application_system_test_case"

class KanbanBoardTest < ApplicationSystemTestCase
  test "operator switches between the live board and grid without losing the preference" do
    project = create_hive_project!("kanban-browser-app")
    slug = create_task!(project, "Move through a native board")
    visit dev_login_path(as: "alice")

    assert_selector "#status-board"
    assert_selector ".kanban-card", text: "Move through a native board"

    click_link "Grid", match: :first
    assert_current_path grid_path
    assert_selector "#status-grid .task-row", text: slug

    visit root_path
    assert_selector "#status-grid", wait: 5

    click_link "Board", match: :first
    assert_current_path board_path
    assert_selector "#status-board .kanban-card", text: slug
  end

  test "board remains contained at a mobile viewport" do
    project = create_hive_project!("kanban-mobile-app")
    create_task!(project, "A deliberately long kanban task title that must stay inside the mobile viewport")
    visit dev_login_path(as: "alice")
    page.current_window.resize_to(375, 812)

    assert_selector "#status-board"
    metrics = page.evaluate_script(<<~JS)
      ({
        viewport: document.documentElement.clientWidth,
        documentWidth: document.documentElement.scrollWidth,
        boardWidth: document.querySelector("#status-board").scrollWidth
      })
    JS
    assert_operator metrics.fetch("documentWidth"), :<=, metrics.fetch("viewport") + 1
    assert_operator metrics.fetch("boardWidth"), :>=, metrics.fetch("viewport") - 30,
                    "the columns should scroll inside the board rather than widening the page"
  end
end
