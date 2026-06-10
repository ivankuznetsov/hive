require "application_system_test_case"

# Browser-level happy path over the real pipeline: sign in (dev seam), see
# the grid, compose an idea with an attached image (upload button path),
# watch the new task arrive over Turbo Streams WITHOUT a reload, approve it
# through a gate. Page-object style: interactions go through the helpers
# below, not raw selectors in test bodies.
class PipelineFlowTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!
    StatusBroadcaster.start!
  end

  teardown do
    StatusBroadcaster.stop!
  end

  # --- page object helpers -------------------------------------------------

  def compose_idea(text)
    fill_in "New idea", with: text
  end

  def attach_composer_image(path)
    # The picker input is visually hidden by design; Capybara must still
    # drive the real element (make_visible only unhides, the change event
    # and Stimulus pipeline run exactly as for a user).
    attach_file path do
      find("button[aria-label='Attach image']").click
    end
  end

  def submit_idea
    click_button "Add idea"
  end

  def task_row(text)
    find(".task-row", text: text, wait: 5)
  end

  # --- tests ---------------------------------------------------------------

  test "login gate, composer with image, live stream update, approve" do
    # Unauthenticated → login page, nothing leaks.
    visit "/"
    assert_selector "h1", text: "hivebox", wait: 5
    assert_button "Continue with GitHub"
    assert_no_selector ".task-row", wait: 0

    sign_in!

    # Composer: attach an image via the upload button; the placeholder must
    # appear in the text and a removable chip must render.
    compose_idea "Browser test idea"
    attach_composer_image fixture_image
    assert_field "New idea", with: /\[image1\]/,
                 wait: 5
    assert_selector ".chip", text: "image1", count: 1

    submit_idea
    assert_selector ".flash-notice", text: "Idea added", wait: 5

    # The task folder + asset must exist on disk (real Commands::New ran).
    folder = stage_dir(@project, "1-inbox").children
                                           .find { |c| c.basename.to_s.start_with?("browser-test-idea") }
    assert folder, "the composed idea must become a 1-inbox task"
    assert folder.join("assets", "image1.png").file?, "the attached image must land in assets/"

    # Live update: a task created OUTSIDE the browser (CLI path) must appear
    # in the open grid via Turbo Streams — no reload, no polling JS.
    row_count_before = all(".task-row").size
    create_task!(@project, "Streamed from the CLI")
    assert_selector ".task-row", text: /streamed from the cli/i, wait: 10
    assert_operator all(".task-row").size, :>, row_count_before,
                    "the new row must arrive over the stream, not a reload"

    # Approve through the task page (force-free path is gated; the grid is
    # the redirect target).
    task_row("Browser test idea").find("a", match: :first).click
    assert_selector "h1", text: "Browser test idea", wait: 5
    # An unforced approve on an unmarked stage must surface the typed
    # refusal, not a blank 500 — then the confirmed force path advances.
    click_button "Approve", match: :first
    assert_selector "h1", text: "Action failed", wait: 5
    assert_text "forward approve requires"
    click_link "Back to status"
    task_row("Browser test idea").find("a", match: :first).click
    assert_selector "h1", text: "Browser test idea", wait: 5
    accept_confirm { click_button "Force approve" }
    assert_selector ".flash-notice", text: "Approved", wait: 5
    assert stage_dir(@project, "2-brainstorm").children.any? { |c| c.basename.to_s.start_with?("browser-test-idea") },
           "approve must move the task into 2-brainstorm"
  end

  test "pasting an image attaches it like the TUI" do
    sign_in!
    compose_idea "Pasted screenshot"

    # Clipboard paste cannot be driven by real input in headless automation;
    # a synthetic paste event with a DataTransfer file is the sanctioned
    # last-resort JS here (house rule 7's explicit exception). Everything
    # downstream — Stimulus handler, renaming, chip, form submit — is real.
    execute_script(<<~JS)
      const input = document.querySelector("textarea[name='text']")
      const data = new DataTransfer()
      data.items.add(new File([new Uint8Array([137,80,78,71,13,10,26,10])], "shot.png", { type: "image/png" }))
      const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })
      input.dispatchEvent(event)
    JS

    assert_field "New idea", with: /\[image1\]/,
                 wait: 5
    assert_selector ".chip", text: "image1", count: 1

    submit_idea
    assert_selector ".flash-notice", text: "Idea added", wait: 5
    folder = stage_dir(@project, "1-inbox").children
                                           .find { |c| c.basename.to_s.start_with?("pasted-screenshot") }
    assert folder.join("assets", "image1.png").file?, "the pasted image must land in assets/"
  end

  private

  def fixture_image
    path = File.join(ENV["HIVE_TEST_HOME_ROOT"], "fixture.png")
    unless File.exist?(path)
      png = [ 137, 80, 78, 71, 13, 10, 26, 10 ].pack("C*")
      File.binwrite(path, png + "fake-png-body")
    end
    path
  end
end
