require "application_system_test_case"

class KanbanBoardAccessibilityTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!("a11y-#{name.parameterize}")
    create_task!(@project, "Accessible board task")
    create_task!(@project, "Second accessible board task")
    configure_owner!
    sign_in!
  end

  test "board has zero serious automated accessibility violations" do
    visit board_path(project: @project)

    assert_selector ".board-card[tabindex='0']", wait: 5
    assert_no_serious_accessibility_violations
  end

  test "board exposes keyboard, focus, and ARIA contracts" do
    visit board_path(project: @project)

    cards = all(".board-card", minimum: 2)
    cards.first.send_keys(:down)
    assert_equal cards[1][:id], page.evaluate_script("document.activeElement.id")
    assert_equal [ "-1", "0" ], cards.first(2).map { |card| card[:tabindex] }

    cards[1].find("summary", text: "Move to").send_keys(:enter)
    cards[1].find(".card-menu-item", match: :first).send_keys(:escape)
    assert_equal "SUMMARY", page.evaluate_script("document.activeElement.tagName")

    assert_selector ".board-columns[role='list'][aria-label]"
    assert_selector ".board-column[role='listitem'][aria-label]", minimum: 1
    assert_selector "[aria-live='polite'][aria-atomic='true']", count: 1
  end

  test "reduced motion disables dragging and animation" do
    visit board_path(project: @project)
    emulate_reduced_motion!(true)

    assert_equal true, page.evaluate_script("matchMedia('(prefers-reduced-motion: reduce)').matches")
    assert_selector ".board-card[draggable='false']", minimum: 2, wait: 5
    assert_operator page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.board-card')).transitionDuration)"),
      :<=, 0.001
  ensure
    emulate_reduced_motion!(false) if page.driver
  end
end
