require "application_system_test_case"

class KanbanBoardActionsTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!("actions-#{name.parameterize}")
    @slug = create_task!(@project, "Move this board card")
    Hive::Markers.set(stage_dir(@project, "1-inbox").join(@slug, "idea.md").to_s, :complete)
    StatusBroadcaster.start!
    sign_in!
    visit board_path(project: @project)
  end

  teardown do
    StatusBroadcaster.stop!
  end

  test "keyboard Move-to form applies the server-returned transition" do
    within board_card do
      find("summary", text: "Move to").send_keys(:enter)
      find_button("Move to Brainstorm").send_keys(:enter)
    end

    assert_selector ".board-column[data-stage='1-inbox'] .board-card:not(.is-transition-pending) .board-chip",
      text: "queue", wait: 10
    assert_predicate stage_dir(@project, "1-inbox").join(@slug), :directory?
    request = Hive::Daemon::DispatchRequestQueue.pending.find { |entry| entry.slug == @slug }
    assert_equal "2-brainstorm", request.transition_destination
    assert_selector "[aria-live='polite']", count: 1
  end

  test "desktop drag uses the same guarded move and illegal columns stay inert" do
    source = board_card
    assert_equal true, source[:draggable]

    source.drag_to(find(".board-column[data-stage='9-done']"))
    assert_predicate stage_dir(@project, "1-inbox").join(@slug), :directory?

    source.drag_to(find(".board-column[data-stage='2-brainstorm']"))
    assert_selector ".board-column[data-stage='1-inbox'] .board-card:not(.is-transition-pending) .board-chip",
      text: "queue", wait: 10
    assert_predicate stage_dir(@project, "1-inbox").join(@slug), :directory?
    request = Hive::Daemon::DispatchRequestQueue.pending.find { |entry| entry.slug == @slug }
    assert_equal "2-brainstorm", request.transition_destination
  end

  private

  def board_card
    find(".board-band[data-project-name='#{@project}'] .board-card", text: /Move this board card/i)
  end
end
