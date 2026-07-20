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
    # Explicit project choice: the sandbox accumulates projects across tests
    # in one process, so the single-project preselect cannot be relied on.
    find(".composer select[name='project']").find("option[value='#{@project}']").select_option
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

    # Reproduce the filesystem broadcaster winning the race against the POST:
    # a page-wide refresh at submit-start must not abort the originating form.
    # Other clients remain eligible for the refresh, and targeted grid streams
    # on this page remain eligible too.
    page.execute_script <<~JS
      document.addEventListener("turbo:submit-start", () => {
        const stream = document.createElement("turbo-stream")
        stream.setAttribute("action", "refresh")
        document.documentElement.appendChild(stream)
      }, { once: true })
    JS
    submit_idea
    assert_selector ".flash-notice", text: "Idea added", wait: 5
    assert page.has_field?("New idea", with: "", wait: 5),
           "a submitted permanent composer must not retain a duplicate-ready draft"
    assert_no_selector ".chip", wait: 0
    assert_equal 0, page.evaluate_script("document.querySelector('[data-composer-target=\"files\"]').files.length"),
                 "successful submission must release the staged upload transport"
    assert_equal @project, find(".composer select[name='project']").value,
                 "clearing the completed draft should retain the operator's project context"

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
    task_href = "/tasks/#{@project}/#{folder.basename}"
    assert_selector ".task-row a[href='#{task_href}']", text: "Browser test idea", wait: 5
    visit task_href
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

  test "a failed Turbo submission keeps the draft and staged attachment" do
    sign_in!
    compose_idea "Keep this failed draft"
    attach_composer_image fixture_image
    assert_selector ".chip", text: "image1", count: 1

    execute_script(<<~JS)
      document.querySelector("#composer").dispatchEvent(new CustomEvent("turbo:submit-end", {
        bubbles: true,
        detail: { success: false, fetchResponse: { statusCode: 422 } }
      }))
    JS

    assert_equal "Keep this failed draft [image1]", find("textarea[aria-label='New idea']").value
    assert_selector ".chip", text: "image1", count: 1
    assert_equal 1, page.evaluate_script(
      "document.querySelector('[data-composer-target=files]').files.length"
    ), "a 422 must leave the upload transport retryable"
  end

  test "a successful response clears the permanent composer before Turbo renders" do
    sign_in!
    compose_idea "Clear this completed draft"
    attach_composer_image fixture_image
    assert_selector ".chip", text: "image1", count: 1

    execute_script(<<~JS)
      document.querySelector("#composer").dispatchEvent(new CustomEvent("turbo:before-fetch-response", {
        bubbles: true,
        detail: { fetchResponse: { succeeded: true } }
      }))
    JS

    assert_equal "", find("textarea[aria-label='New idea']").value
    assert_no_selector ".chip", wait: 0
    assert_equal 0, page.evaluate_script(
      "document.querySelector('[data-composer-target=files]').files.length"
    ), "a successful response must release the upload before a permanent-node reconnect"
    assert_equal @project, find(".composer select[name='project']").value
  end

  test "composer reconnect rebuilds staged attachments before adding another" do
    sign_in!
    compose_idea "Reconnect attachments"
    attach_composer_image fixture_image
    assert_selector ".chip", text: "image1", count: 1

    # Move the exact permanent form out and back across animation frames. This
    # drives a real Stimulus disconnect/connect while preserving the browser's
    # FileList, matching Turbo moving a permanent node into a morphed document.
    execute_script(<<~JS)
      const form = document.querySelector("#composer")
      const marker = document.createComment("composer reconnect marker")
      form.before(marker)
      form.remove()
      requestAnimationFrame(() => {
        marker.after(form)
        requestAnimationFrame(() => { form.dataset.testReconnected = "true" })
      })
    JS
    assert_selector "#composer[data-test-reconnected='true']", wait: 5

    attach_composer_image fixture_image

    assert_selector ".chip", text: "image1", count: 1
    assert_selector ".chip", text: "image2", count: 1
    names = page.evaluate_script(
      "Array.from(document.querySelector('[data-composer-target=files]').files).map(file => file.name)"
    )
    assert_equal %w[image1.png image2.png], names,
                 "reconnect must restore image1 before image2 rebuilds the transport"

    submit_idea
    assert_selector ".flash-notice", text: "Idea added", wait: 5
    folder = stage_dir(@project, "1-inbox").children
                                           .find { |child| child.basename.to_s.start_with?("reconnect-attachments") }
    assert folder.join("assets", "image1.png").file?
    assert folder.join("assets", "image2.png").file?
  end

  test "an ownerless box offers the claim flow, not config-editing homework" do
    # No web config at all: the shipped client_id default makes the box
    # CLAIMABLE out of the box — the first sign-in becomes the owner.
    path = File.join(ENV["HIVE_HOME"], "config.yml")
    data = YAML.safe_load_file(path) || {}
    data.delete("web")
    File.write(path, data.to_yaml)

    visit "/login"

    assert_text "first GitHub sign-in becomes its owner"
    assert_button "Continue with GitHub"
  end

  test "the project rail filters the grid and survives live updates" do
    second = create_hive_project!("second-app")
    create_task!(@project, "Demo task one")
    create_task!(second, "Second task one")
    sign_in!
    visit "/"
    assert_selector ".project-section[data-project-name='#{@project}']"
    assert_selector ".project-section[data-project-name='second-app']"

    click_button @project
    assert_selector ".project-section[data-project-name='#{@project}']"
    assert_no_selector ".project-section[data-project-name='second-app']",
                       wait: 5
    assert_includes page.current_url, "project=#{@project}",
                    "the choice must reach the URL so reloads land filtered"
    assert_equal @project, find(".composer select[name='project']").value,
                 "filtering is a context switch — new ideas should land in that project"

    # The broadcast REPLACES the grid, discarding our hidden attributes —
    # the filter must re-apply itself on the fresh DOM.
    create_task!(second, "Second task two")
    assert_selector ".project-section[data-project-name='second-app'][hidden]",
                    visible: :hidden, wait: 10
    assert_selector ".task-row", text: "Demo task one",
                    count: 1

    click_button "All projects"
    assert_selector ".project-section[data-project-name='second-app']"
    assert_selector ".task-row", text: "Second task two"
    assert_equal @project, find(".composer select[name='project']").value,
                 "widening the view must not discard the composer's project choice"

    click_link "+ Add project"
    assert_current_path "/repos"
  end

  test "a project deep link lands filtered with the composer preselected" do
    second = create_hive_project!("second-app")
    create_task!(@project, "Demo deep task")
    create_task!(second, "Second deep task")
    sign_in!

    visit "/?project=#{@project}"
    assert_selector ".project-section[data-project-name='#{@project}']"
    assert_selector ".project-section[data-project-name='second-app']", count: 0
    assert_equal @project, find(".composer select[name='project']").value,
                 "a filtered deep link must preselect the composer"

    # Ghost link (renamed/forgotten project): never an empty grid — fall
    # back to All projects and clean the URL.
    visit "/?project=ghost-app"
    assert_selector ".project-section[data-project-name='#{@project}']"
    assert_selector ".project-section[data-project-name='second-app']"
    assert_selector ".project-nav-item.active", text: "All projects"
    refute_includes page.current_url, "ghost-app",
                    "the dead filter must not survive in the URL"
  end

  test "grid updates preserve scroll position and composer state" do
    # Enough rows to overflow the viewport so window scroll is meaningful.
    30.times { |n| create_task!(@project, "Filler idea number #{n}") }
    sign_in!
    visit "/"
    assert_selector ".task-row", text: "Filler idea number 29", wait: 10
    fill_in "New idea", with: "half-typed thought"

    # Window scroll is unobservable through user-facing APIs — the sanctioned
    # JS exception, used only to position and read scrollY.
    page.execute_script("window.scrollTo(0, 400)")
    scrolled_to = page.evaluate_script("window.scrollY")
    assert_operator scrolled_to, :>, 0, "the grid must overflow the viewport for this test to mean anything"

    create_task!(@project, "Live arrival probe")
    assert_selector ".task-row", text: "Live arrival probe", wait: 10

    assert_equal scrolled_to, page.evaluate_script("window.scrollY"),
                 "a grid update must not yank the operator back to the top"
    assert_equal "half-typed thought", find("textarea[aria-label='New idea']").value,
                 "a grid update must not clear the composer"
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
    # Provably outlast TWO real poll ticks: the controller counts every
    # timer firing (including paused ones) in data-poll-ticks, so waiting
    # for the counter to advance is an explicit wait, not a sleep — and a
    # deleted readerBusy() would fail the absence assertions below.
    ticks = page.evaluate_script("Number(document.querySelector('#task-log').dataset.pollTicks || 0)")
    assert_selector "#task-log[data-poll-ticks='#{ticks + 2}']", wait: 10
    assert_selector "pre[data-tail-follow][data-following='false']"
    assert_no_text "marker-while-reading"
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

  test "task page shows captured visual demo media" do
    slug = create_task!(@project, "Media probe")
    folder = stage_dir(@project, "1-inbox").join(slug)
    write_media_manifest(folder, captured_media_manifest)
    media_dir = folder.join("media")
    File.binwrite(media_dir.join("01-home.png"), png_bytes)
    File.binwrite(media_dir.join("demo.gif"), gif_bytes)

    sign_in!
    visit "/tasks/#{@project}/#{slug}"

    assert_selector "section.demo h2", text: "Demo", wait: 5
    assert_selector "section.demo img[alt='Home page after load']", visible: true
    assert_selector "section.demo img[alt='Dark mode toggle']", visible: true
    assert_link "View / annotate on screenote", href: "https://screenote.test/shot"
  end

  test "task page shows failed demo capture without images" do
    slug = create_task!(@project, "Failed media probe")
    folder = stage_dir(@project, "1-inbox").join(slug)
    write_media_manifest(folder, {
      "schema" => 1,
      "status" => "failed",
      "reason" => "dev server did not boot",
      "surface" => "ui",
      "items" => []
    })

    sign_in!
    visit "/tasks/#{@project}/#{slug}"

    assert_selector ".demo-banner", text: /Demo capture failed/, wait: 5
    assert_selector ".demo-banner", text: /dev server did not boot/
    assert_no_selector "section.demo img"
  end

  test "a new question round replaces the Q&A form cleanly" do
    folder = stage_dir(@project, "1-inbox").join(create_task!(@project, "Round probe"))
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n<!-- WAITING -->\n")
    sign_in!
    visit "/tasks/#{@project}/#{folder.basename}"
    assert_selector "form[id='qa-form-1']", wait: 5

    # The agent answers Q1 and asks Q2 — the open set changes [1] → [2].
    folder.join("brainstorm.md").write(
      "### Q1. Scope?\n\n### A1.\nDone\n\n### Q2. Deadline?\n\n### A2.\n\n<!-- WAITING -->\n"
    )
    create_task!(@project, "Round trigger")

    assert_selector "form[id='qa-form-2']", wait: 10
    # Capybara assertions carry no custom messages; the selectors are the doc:
    # the previous round's form must not linger, and exactly one form remains.
    assert_selector "form[id='qa-form-1']", count: 0
    assert_selector "form[id^='qa-form-']", count: 1
    assert_selector ".qa-question", text: /Deadline/
  end

  test "typing in the Q&A survives a pushed morph refresh" do
    folder = stage_dir(@project, "1-inbox").join(create_task!(@project, "Focus probe"))
    folder.join("brainstorm.md").write("### Q1. Scope?\n\n### A1.\n\n<!-- WAITING -->\n")
    sign_in!
    visit "/tasks/#{@project}/#{folder.basename}"

    field = find("textarea[name='answers[1]']", wait: 5)
    field.fill_in with: "typing slowly"
    # Change the task's OWN visible content, then force a broadcast → morph.
    # Waiting for the updated question text is the sync point proving the
    # morph actually landed before we assert survival — without it every
    # assertion could pass against the pre-morph DOM.
    folder.join("brainstorm.md").write("### Q1. Scope? (clarified)\n\n### A1.\n\n<!-- WAITING -->\n")
    create_task!(@project, "Refresh trigger")
    assert_selector ".qa-question", text: /clarified/, wait: 10
    assert_equal "typing slowly", find("textarea[name='answers[1]']").value,
                 "a pushed morph must not discard typed-but-unsent input"
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

  def write_media_manifest(folder, manifest)
    media_dir = folder.join("media")
    media_dir.mkpath
    media_dir.join("manifest.json").write("#{JSON.pretty_generate(manifest)}\n")
  end

  def captured_media_manifest
    {
      "schema" => 1,
      "status" => "captured",
      "surface" => "ui",
      "items" => [
        {
          "file" => "01-home.png",
          "type" => "still",
          "caption" => "Home page after load",
          "screenote_url" => "https://screenote.test/shot"
        },
        {
          "file" => "demo.gif",
          "type" => "gif",
          "caption" => "Dark mode toggle",
          "screenote_url" => nil,
          "screenote_skipped_reason" => "Screenote is not connected; run `hive connect screenote`."
        }
      ]
    }
  end

  def png_bytes
    [ 137, 80, 78, 71, 13, 10, 26, 10 ].pack("C*") + "fake-png-body"
  end

  def gif_bytes
    "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;".b
  end
end
