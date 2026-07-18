require "application_system_test_case"

class KanbanBoardTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!("board-#{name.parameterize}")
    create_task!(@project, "Keyboard board task")
    configure_owner!
    StatusBroadcaster.start!
    sign_in!
    visit board_path
  end

  teardown do
    StatusBroadcaster.stop!
    page.current_window.resize_to(1280, 900)
  end

  test "cards are keyboard navigable and live CLI changes arrive" do
    assert_selector ".board-card[tabindex='0']", wait: 5
    band = find(".board-band[data-project-name='#{@project}']")
    card = band.find(".board-card", text: /Keyboard board task/i)
    card.send_keys(:enter)
    assert_selector "h1", text: /Keyboard board task/i, wait: 5

    visit board_path
    create_task!(@project, "Live board arrival")
    within ".board-band[data-project-name='#{@project}']" do
      assert_selector ".board-card", text: /Live board arrival/i, wait: 10
    end
    assert_selector "[aria-live='polite']", count: 1
  end

  test "mobile uses a stage pager instead of a horizontal wall" do
    page.current_window.resize_to(375, 800)
    visit board_path

    assert_selector ".stage-pager", visible: true, wait: 5
    select "Brainstorm", from: "Stage for #{@project}"
    assert_selector ".board-column[data-stage='2-brainstorm']:not([hidden])", visible: true
    assert_selector ".board-column[data-stage='1-inbox'][hidden]", visible: :hidden
  end
end
