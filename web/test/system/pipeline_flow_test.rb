require "application_system_test_case"

# Browser-level happy path over the real pipeline: sign in (dev seam), see
# the grid, compose an idea with an attached image (upload button path),
# watch the new task arrive over Turbo Streams WITHOUT a reload, approve it
# through a gate. Page-object style: interactions go through the helpers
# below, not raw selectors in test bodies.
class PipelineFlowTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!
    configure_owner!
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
    # The state machine drives the buttons: an unmarked stage offers no
    # doomed Approve as a headline action — the Force override lives in the
    # Advanced section at the bottom, confirm-gated.
    assert_no_button "Approve", exact: true, wait: 0
    find(".advanced summary").click
    accept_confirm { within(".advanced") { click_button "Force approve" } }
    assert_selector ".flash-notice", text: "Approved", wait: 5
    assert stage_dir(@project, "2-brainstorm").children.any? { |c| c.basename.to_s.start_with?("browser-test-idea") },
           "approve must move the task into 2-brainstorm"
  end

  test "an unconfigured box explains setup instead of a dead sign-in button" do
    path = File.join(ENV["HIVE_HOME"], "config.yml")
    data = YAML.safe_load_file(path) || {}
    data.delete("web")
    File.write(path, data.to_yaml)

    visit "/login"

    assert_text "know its owner"
    assert_no_button "Continue with GitHub", wait: 0
  end

  test "log pane follows the tail, pauses for reading, resumes at the bottom" do
    slug = create_task!(@project, "Tail probe")
    log_dir = Pathname(ENV["HIVE_TEST_HOME_ROOT"]).join("repos", @project, ".hive-state", "logs", slug)
    log_dir.mkpath
    log_file = log_dir.join("stage-20260611T000000Z.log")
    log_file.write((1..120).map { |n| "line #{n}" }.join("\n") + "\n")

    sign_in!
    visit "/tasks/#{@project}/#{slug}"
    pane = find("pre[data-tail-follow]", wait: 5)
    assert pane.text.include?("line 120"), "the tail must show the newest lines"
    # The controller stamps data-following once it pins — the explicit wait
    # for "Stimulus has booted and taken over", instead of racing it.
    assert_selector "pre[data-tail-follow][data-following]", wait: 5

    # Scroll geometry is unobservable through user-facing APIs, and
    # capybara-playwright cannot wheel-scroll an inner pane — the sanctioned
    # JS exception, used only to position and read scrollTop.
    distance_from_bottom = page.evaluate_script(
      "(() => { const p = document.querySelector('pre[data-tail-follow]'); return p.scrollHeight - p.scrollTop - p.clientHeight; })()"
    )
    assert_operator distance_from_bottom, :<=, 8, "the pane must start pinned to the live end (tail -f)"

    page.execute_script("document.querySelector('pre[data-tail-follow]').scrollTop = 0")
    log_file.write("line 121 marker-while-reading\n", mode: "a")
    # Outlast a 3s poll tick: a paused pane must neither move nor refresh.
    assert_no_text "marker-while-reading", wait: 5
    assert_equal 0, page.evaluate_script("document.querySelector('pre[data-tail-follow]').scrollTop"),
                 "reading position must survive poll ticks"

    page.execute_script("const p = document.querySelector('pre[data-tail-follow]'); p.scrollTop = p.scrollHeight")
    assert_text "marker-while-reading", wait: 10

    # No-blink contract: reloads MORPH the pane (patch, not replace). Tag the
    # live DOM node, let the next refresh bring a new line in, and verify the
    # same node survived — a child-replacing reload (the old behavior, a
    # visible 3s blink) would have swapped it out. This line appearing at all
    # also proves the pane re-pinned after the previous morph: an unpinned
    # pane pauses the poll.
    page.execute_script("document.querySelector('pre[data-tail-follow]').__sameNode = true")
    log_file.write("line 122 after-morph\n", mode: "a")
    assert_text "after-morph", wait: 10
    assert page.evaluate_script("document.querySelector('pre[data-tail-follow]').__sameNode"),
           "a poll refresh must patch the pane in place, not rebuild it"
  end

  test "artifact open state survives a pushed morph while content stays live" do
    slug = create_task!(@project, "Artifact probe")
    folder = stage_dir(@project, "1-inbox").join(slug)
    folder.join("brainstorm.md").write("first draft\n")

    sign_in!
    visit "/tasks/#{@project}/#{slug}"
    second = find("details[data-artifact-name='brainstorm.md']", wait: 5)
    refute second[:open], "only the first artifact starts open"
    second.find("summary").click
    assert second[:open], "clicking the summary must expand the artifact"

    # Change the artifact on disk and force a status change → broadcast →
    # morph. The open choice must survive AND the content must update —
    # preservation may not come at the price of staleness.
    folder.join("brainstorm.md").write("first draft\nsecond draft line\n")
    create_task!(@project, "Refresh trigger")
    assert_text "second draft line", wait: 10
    assert find("details[data-artifact-name='brainstorm.md']")[:open],
           "the operator's open choice must survive the morph"
  end

  test "typing in the Q&A survives a pushed morph refresh" do
    folder = stage_dir(@project, "1-inbox").join(create_task!(@project, "Focus probe"))
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n<!-- WAITING -->\n")
    sign_in!
    visit "/tasks/#{@project}/#{folder.basename}"

    field = find("textarea[name='answers[1]']", wait: 5)
    field.fill_in with: "typing slowly"
    # Force a status change → StatusBroadcaster pushes a refresh → the page
    # morphs. The permanent Q&A form must keep both the text and the caret.
    create_task!(@project, "Refresh trigger")
    assert_selector ".task-header", wait: 10
    using_wait_time(8) do
      assert_equal "typing slowly", find("textarea[name='answers[1]']").value,
                   "a pushed morph must not discard typed-but-unsent input"
    end
    field.send_keys(" still here")
    assert_equal "typing slowly still here", find("textarea[name='answers[1]']").value,
                 "focus must remain in the field across refreshes"
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
