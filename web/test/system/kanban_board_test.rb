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
    assert_selector "[role='dialog'] h2", text: /Keyboard board task/i, wait: 5

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

  test "refresh-required generations and cable reconnects reconcile authoritatively" do
    page.execute_script(<<~JS)
      document.documentElement.dataset.boardVisits = "0"
      document.addEventListener("turbo:before-visit", (event) => {
        const root = document.documentElement
        root.dataset.boardVisits = String(Number(root.dataset.boardVisits) + 1)
        event.preventDefault()
      })
      const sync = document.querySelector("#board_sync")
      const replacement = sync.cloneNode(true)
      replacement.dataset.generation = String(Number(sync.dataset.generation) + 1)
      replacement.dataset.refreshRequired = "true"
      sync.replaceWith(replacement)
    JS
    assert_selector "html[data-board-visits='1']"
    assert_text "Board update requires a full refresh"

    page.execute_script(<<~JS)
      document.dispatchEvent(new CustomEvent("turbo:fetch-request-error"))
      const sync = document.querySelector("#board_sync")
      const replacement = sync.cloneNode(true)
      replacement.dataset.generation = String(Number(sync.dataset.generation) + 2)
      replacement.dataset.refreshRequired = "false"
      sync.replaceWith(replacement)
    JS
    assert_selector "html[data-board-visits='2']"

    page.execute_script(<<~JS)
      document.dispatchEvent(new CustomEvent("turbo:fetch-request-error"))
      const source = document.querySelector("turbo-cable-stream-source")
      source.setAttribute("connected", "")
      source.removeAttribute("connected")
      source.setAttribute("connected", "")
    JS
    assert_selector "html[data-board-visits='3']"
    assert_text "Board reconnected; refreshing current state"
  end
end
