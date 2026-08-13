require "application_system_test_case"

class TaskWorkspaceTest < ApplicationSystemTestCase
  setup do
    @project = create_hive_project!("task-workspace-app")
    @slug = create_task!(
      @project,
      "Keep exact attempt, context, dependency, publication, and operator evidence readable"
    )
    @folder = stage_dir(@project, "1-inbox").join(@slug)
  end

  teardown { StatusBroadcaster.stop! }

  test "one semantic workspace reflows from wide desktop through an effective 320 CSS pixel viewport" do
    sign_in!
    visit task_path(@project, @slug)
    assert_selector "#workspace-summary", wait: 10

    [ [ 1280, 800 ], [ 3840, 1400 ], [ 375, 812 ], [ 320, 568 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      metrics = page.evaluate_script(<<~JS)
        (() => {
          const root = document.documentElement
          const panels = Array.from(document.querySelectorAll(".workspace-panel, .workspace-summary"))
          const clippedPanels = panels.filter((panel) => {
            const rect = panel.getBoundingClientRect()
            return rect.left < -1 || rect.right > root.clientWidth + 1
          }).length
          return {
            viewport: root.clientWidth,
            documentWidth: root.scrollWidth,
            clippedPanels,
            columns: getComputedStyle(document.querySelector(".task-workspace-grid")).gridTemplateColumns
          }
        })()
      JS

      assert_operator metrics.fetch("documentWidth"), :<=, metrics.fetch("viewport") + 1,
                      "task workspace overflowed at #{width}x#{height}"
      assert_equal 0, metrics.fetch("clippedPanels"),
                   "a workspace panel was clipped at #{width}x#{height}"
      if width >= 1280
        assert_match(/\s/, metrics.fetch("columns"), "desktop workspace should expose two columns")
      end
    end

    assert_selector "#status-stream-owner > .task-header > h1", count: 1
    assert_selector "#workspace-attempts h2", text: "Attempts and resources"
    assert_selector "#workspace-provenance h2", text: "Context provenance"
    assert_selector "#workspace-timeline h2", text: "Audit timeline"
    assert_selector "#workspace-dependencies h2", text: "Dependency component"
    assert_selector "#workspace-dependencies table", minimum: 1

    undersized = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#status-stream-owner button, #status-stream-owner summary"))
        .filter((element) => {
          const style = getComputedStyle(element)
          const rect = element.getBoundingClientRect()
          return style.display !== "none" && style.visibility !== "hidden" &&
            (rect.width < 24 || rect.height < 24)
        })
        .map((element) => ({ text: element.textContent.trim(), width: element.offsetWidth, height: element.offsetHeight }))
    JS
    assert_empty undersized, "named controls must meet the 24 CSS pixel minimum"
  end

  test "keyboard users can reach disclosures and the semantic dependency alternative" do
    sign_in!
    visit task_path(@project, @slug)
    assert_selector "#workspace-artifacts details[data-artifact-name='idea.md']", wait: 10

    artifact = find("#workspace-artifacts details[data-artifact-name='idea.md']")
    summary = artifact.find("summary")
    summary.click
    refute artifact[:open]
    summary.send_keys(:enter)
    assert artifact[:open]
    assert_equal "SUMMARY", page.evaluate_script("document.activeElement.tagName")

    summary.send_keys(:tab)
    assert page.evaluate_script("document.activeElement !== document.body"),
           "Tab must continue through the task controls"
    assert_selector ".workspace-table-scroll[role='region'][tabindex='0']", minimum: 1
    assert_selector "#workspace-dependencies table caption",
                    text: /Authoritative bounded node and edge relationships/
  end

  test "pushed morphs preserve workspace ownership and announce only material changes" do
    @folder.join("brainstorm.md").write("draft context\n")
    sign_in!
    page.current_window.resize_to(1280, 600)
    visit task_path(@project, @slug)
    assert_selector "#workspace-summary-heading", wait: 10
    wait_for_live_status

    disclosure = find("details[data-workspace-disclosure-key='provenance-diagnostics']")
    disclosure.find("summary").click
    assert disclosure[:open]
    artifact = find("details[data-artifact-name='brainstorm.md']")
    artifact.find("summary").click
    assert artifact[:open]
    execute_script(<<~JS)
      document.querySelector("turbo-frame[id^='task-publication-']").__workspaceOwned = true
      document.querySelector("turbo-frame[id^='task-diff-']").__workspaceOwned = true
      document.querySelector("details[data-workspace-disclosure-key='provenance-diagnostics'] summary").focus()
      window.scrollTo(0, Math.min(500, document.documentElement.scrollHeight - innerHeight))
    JS
    original_scroll = page.evaluate_script("window.scrollY")

    # An equivalent decision update must not produce a live-region message.
    @folder.join("brainstorm.md").write("draft context\nmore detail\n")
    create_task!(@project, "Equivalent workspace refresh trigger")
    assert_text "more detail", wait: 10
    assert_equal "", page.evaluate_script("document.querySelector('#task-workspace-announcement').textContent")
    assert find("details[data-workspace-disclosure-key='provenance-diagnostics']")[:open]
    assert find("details[data-artifact-name='brainstorm.md']")[:open]
    assert page.evaluate_script("document.querySelector(\"turbo-frame[id^='task-publication-']\").__workspaceOwned")
    assert page.evaluate_script("document.querySelector(\"turbo-frame[id^='task-diff-']\").__workspaceOwned")
    assert_in_delta original_scroll, page.evaluate_script("window.scrollY"), 2

    Hive::Markers.set(@folder.join("idea.md").to_s, :complete)
    create_task!(@project, "Material workspace refresh trigger")
    assert_selector "#workspace-summary-heading", text: "Approve", wait: 10
    Timeout.timeout(5) do
      sleep 0.01 until page.evaluate_script(
        "document.querySelector('#task-workspace-announcement').textContent.includes('Approve')"
      )
    end
    assert find("details[data-workspace-disclosure-key='provenance-diagnostics']")[:open]
    assert_equal "provenance-diagnostics",
                 page.evaluate_script("document.activeElement.closest('details')?.dataset.workspaceDisclosureKey")
  end
end
