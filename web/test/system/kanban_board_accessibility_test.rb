require "application_system_test_case"

class KanbanBoardAccessibilityTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!("a11y-#{name.parameterize}")
    create_task!(@project, "Accessible board task")
    configure_owner!
    sign_in!
  end

  test "board has zero serious automated accessibility violations" do
    visit board_path(project: @project)

    assert_selector ".board-card[tabindex='0']", wait: 5
    assert_no_serious_accessibility_violations
  end
end
