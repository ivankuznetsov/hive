require "application_system_test_case"

class KanbanBoardDrawerTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!("drawer-#{name.parameterize}")
    @slug = create_task!(@project, "Inspect this task")
    StatusBroadcaster.start!
    sign_in!
    visit board_path(project: @project)
  end

  teardown do
    StatusBroadcaster.stop!
  end

  test "drawer reuses task details and restores focus when closed" do
    card = find(".board-band[data-project-name='#{@project}'] .board-card", text: /Inspect this task/i)
    card.find(".board-card-title").click

    assert_selector ".task-drawer-frame.is-open [role='dialog']", wait: 5
    assert_selector "#task_drawer_title", text: /Inspect this task/i
    assert_selector ".task-drawer-body #task-state"
    assert_equal "Close task details", page.evaluate_script("document.activeElement.getAttribute('aria-label')")

    create_task!(@project, "Live sibling while drawer stays open")
    assert_selector ".board-band[data-project-name='#{@project}'] .board-card",
      text: /Live sibling while drawer stays open/i, wait: 10
    assert_selector ".task-drawer-frame.is-open #task_drawer_title", text: /Inspect this task/i

    page.send_keys(:escape)
    assert_no_selector ".task-drawer-frame.is-open"
    assert_equal card[:id], page.evaluate_script("document.activeElement.id")
  end

  test "mobile drawer is a full-screen sheet with a direct deep link" do
    page.current_window.resize_to(375, 800)
    find(".board-band[data-project-name='#{@project}'] .board-card-title", text: /Inspect this task/i).click

    assert_selector ".task-drawer-frame.is-open", wait: 5
    assert_selector "a[data-turbo-frame='_top']", text: "Open page"
    width = page.evaluate_script("document.querySelector('.task-drawer-panel').getBoundingClientRect().width")
    assert_in_delta 375, width, 1
  ensure
    page.current_window.resize_to(1280, 900)
  end
end
