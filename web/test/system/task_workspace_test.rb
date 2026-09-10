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

  test "one semantic workspace reflows from wide desktop through actual 400 percent zoom" do
    sign_in!
    visit task_path(@project, @slug)
    assert_selector "#workspace-summary", wait: 10

    [ [ 1280, 800 ], [ 3840, 1400 ], [ 375, 812 ] ].each do |width, height|
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

    page.current_window.resize_to(1280, 800)
    page.driver.with_playwright_page do |playwright_page|
      cdp = playwright_page.context.new_cdp_session(playwright_page)
      cdp.send_message("Emulation.setDeviceMetricsOverride", params: {
        width: 320, height: 200, deviceScaleFactor: 4, mobile: false
      })
    end
    zoomed = page.evaluate_script(<<~JS)
      (() => {
        const root = document.documentElement
        return {
          viewport: root.clientWidth,
          deviceScaleFactor: window.devicePixelRatio,
          documentWidth: root.scrollWidth,
          clippedPanels: Array.from(document.querySelectorAll(".workspace-panel, .workspace-summary"))
            .filter((panel) => {
              const rect = panel.getBoundingClientRect()
              return rect.left < -1 || rect.right > root.clientWidth + 1
            }).length,
          columns: getComputedStyle(document.querySelector(".task-workspace-grid")).gridTemplateColumns
        }
      })()
    JS
    assert_equal 4, zoomed.fetch("deviceScaleFactor"),
                 "Playwright must apply a real 400% Chromium device scale"
    assert_in_delta 320, zoomed.fetch("viewport"), 1,
                    "400% scale on 1280 physical pixels must expose 320 CSS pixels"
    assert_operator zoomed.fetch("documentWidth"), :<=, zoomed.fetch("viewport") + 1,
                    "task workspace overflowed at actual 400% browser zoom"
    assert_equal 0, zoomed.fetch("clippedPanels"),
                 "a workspace panel was clipped at actual 400% browser zoom"
    refute_match(/\s/, zoomed.fetch("columns"), "400% zoom must reflow to one column")

    assert_selector "#status-stream-owner > .task-header > h1", count: 1
    assert_no_selector "#workspace-attempts"
    assert_no_selector "#workspace-provenance"
    assert_no_selector "#workspace-timeline"
    assert_no_selector "#workspace-usage"
    assert_selector "#workspace-primary-result"
    assert_no_selector "#workspace-dependencies"

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

  test "large markdown artifacts keep a readable measure and contain wide content" do
    wide_value = "unbroken-evidence-#{'a' * 180}"
    @folder.join("idea.md").write(<<~MD)
      # Long-form operator guide

      This document has enough prose to make line length and vertical rhythm
      matter. The task workspace should read like a document rather than dense
      dashboard chrome.

      ## Evidence review

      #{Array.new(12, "Read the evidence carefully, preserve its context, and record the resulting decision.").join("\n\n")}

      ## Evidence review

      Compare the second review without colliding with the first heading.

      ## Delivery

      Keep the final work product first.

      ## Follow-up

      Record what happens next.

      | Evidence | Durable value |
      | --- | --- |
      | receipt | #{wide_value} |

      ```text
      #{wide_value}
      ```
    MD

    sign_in!
    page.current_window.resize_to(1280, 900)
    visit task_path(@project, @slug)
    assert_selector "#workspace-primary-result .markdown h1", text: "Long-form operator guide", wait: 10
    assert_no_selector ".document-outline[open]"
    find(".document-outline > summary").click
    assert_selector ".document-outline[aria-label='Document outline'] a[href='#evidence-review']", count: 1
    assert_selector ".document-outline a[href='#evidence-review-2']", count: 1

    desktop = page.evaluate_script(<<~JS)
      (() => {
        const root = document.documentElement
        const documentBody = document.querySelector("#workspace-primary-result .markdown")
        const bodyStyle = getComputedStyle(documentBody)
        return {
          viewport: root.clientWidth,
          documentWidth: root.scrollWidth,
          panelWidth: documentBody.getBoundingClientRect().width,
          readingWidth: documentBody.querySelector("p").getBoundingClientRect().width,
          evidenceWidth: documentBody.querySelector("table").getBoundingClientRect().width,
          fontSize: parseFloat(bodyStyle.fontSize),
          lineHeight: parseFloat(bodyStyle.lineHeight),
          h1Size: parseFloat(getComputedStyle(documentBody.querySelector("h1")).fontSize),
          h2Size: parseFloat(getComputedStyle(documentBody.querySelector("h2")).fontSize)
        }
      })()
    JS

    assert_operator desktop.fetch("fontSize"), :>=, 16,
                    "long-form artifact prose must use a full-size reading font"
    assert_operator desktop.fetch("lineHeight"), :>=, 27,
                    "long documents need generous leading for scanability"
    assert_operator desktop.fetch("h1Size") / desktop.fetch("fontSize"), :>=, 1.7,
                    "the document title must be visibly distinct from body prose"
    assert_operator desktop.fetch("h2Size") / desktop.fetch("fontSize"), :>=, 1.3,
                    "section headings must establish a clear document hierarchy"
    assert_operator desktop.fetch("readingWidth"), :<=, 900,
                    "long lines must be capped at a comfortable reading measure"
    assert_operator desktop.fetch("panelWidth"), :>, desktop.fetch("readingWidth"),
                    "the document panel should leave desktop room for wide evidence"
    assert_operator desktop.fetch("evidenceWidth"), :>, desktop.fetch("readingWidth"),
                    "tables should use available desktop width without widening prose"
    assert_operator desktop.fetch("documentWidth"), :<=, desktop.fetch("viewport") + 1

    page.current_window.resize_to(375, 812)
    mobile = page.evaluate_script(<<~JS)
      (() => {
        const root = document.documentElement
        const pre = document.querySelector("#workspace-primary-result .markdown pre")
        const table = document.querySelector("#workspace-primary-result .markdown table")
        return {
          viewport: root.clientWidth,
          documentWidth: root.scrollWidth,
          preOverflow: getComputedStyle(pre).overflowX,
          preScrollWidth: pre.scrollWidth,
          preWidth: pre.clientWidth,
          tableOverflow: getComputedStyle(table).overflowX,
          tableScrollWidth: table.scrollWidth,
          tableWidth: table.clientWidth
        }
      })()
    JS

    assert_operator mobile.fetch("documentWidth"), :<=, mobile.fetch("viewport") + 1,
                    "wide Markdown content must not widen the task page"
    assert_includes %w[auto scroll], mobile.fetch("preOverflow")
    assert_operator mobile.fetch("preScrollWidth"), :>, mobile.fetch("preWidth"),
                    "long code must scroll inside its own block"
    assert_includes %w[auto scroll], mobile.fetch("tableOverflow")
    assert_operator mobile.fetch("tableScrollWidth"), :>, mobile.fetch("tableWidth"),
                    "wide tables must scroll inside the document"
  end

  test "pushed morphs preserve the exact Q&A selection range" do
    brainstorm = stage_dir(@project, "2-brainstorm").join(@slug)
    FileUtils.mv(@folder, brainstorm)
    @folder = brainstorm
    @folder.join("brainstorm.md").write(
      "### Q1. Scope?\n\n### A1.\n\n<!-- WAITING -->\n"
    )
    sign_in!
    visit task_path(@project, @slug)
    field = find("textarea[data-question-number='1']", wait: 10)
    field_name = field[:name]
    wait_for_live_status
    Timeout.timeout(5) do
      sleep 0.01 until page.evaluate_script(<<~JS)
        Boolean(window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector("#task-state"), "answers"
        ))
      JS
    end
    stable_version = nil
    stable_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Timeout.timeout(5) do
      loop do
        current_version = find("#status-stream-owner", visible: :all)["data-status-version"]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if current_version == stable_version
          break if now - stable_since >= 0.5
        else
          stable_version = current_version
          stable_since = now
        end
        sleep 0.05
      end
    end
    field = find("textarea[data-question-number='1']")
    page.execute_script(<<~JS, field)
      arguments[0].focus()
      arguments[0].value = "precise selection"
      arguments[0].dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText" }))
      arguments[0].setSelectionRange(2, 9)
      arguments[0].dispatchEvent(new Event("select", { bubbles: true }))
    JS

    idea_path = @folder.join("idea.md")
    idea_path.write(idea_path.read.sub("Keep exact", "Refresh exact"))
    create_task!(@project, "Selection refresh trigger")
    assert_selector ".idea-text", text: /Refresh exact/, wait: 10

    selection = nil
    Timeout.timeout(5) do
      loop do
        selection = page.evaluate_script(<<~JS)
          (() => {
            const field = document.querySelector("textarea[data-question-number='1']")
            return {
              value: field.value,
              name: field.name,
              focused: document.activeElement === field,
              start: field.selectionStart,
              end: field.selectionEnd
            }
          })()
        JS
        break if selection.values_at("value", "start", "end") ==
                 [ "precise selection", 2, 9 ]
        sleep 0.01
      end
    end
    assert_equal field_name, selection.fetch("name"),
                 "the normalized question binding must remain stable across the morph"
    assert_equal "precise selection", selection.fetch("value")
    assert_equal 2, selection.fetch("start")
    assert_equal 9, selection.fetch("end")
  end

  test "keyboard users can reach supporting documents without empty dependency panels" do
    @folder.join("brainstorm.md").write("# Supporting context\n")
    sign_in!
    visit task_path(@project, @slug)
    assert_selector "#workspace-supporting-artifacts details[data-artifact-name='brainstorm.md']", wait: 10

    artifact = find("#workspace-supporting-artifacts details[data-artifact-name='brainstorm.md']")
    summary = artifact.find("summary")
    refute artifact[:open]
    summary.send_keys(:enter)
    assert artifact[:open]
    assert_equal "SUMMARY", page.evaluate_script("document.activeElement.tagName")

    summary.send_keys(:tab)
    assert page.evaluate_script("document.activeElement !== document.body"),
           "Tab must continue through the task controls"
    assert_no_selector "#workspace-dependencies"
  end

  test "pushed morphs preserve workspace ownership and announce only safe decisions" do
    @folder.join("brainstorm.md").write("draft context\n")
    sign_in!
    page.current_window.resize_to(1280, 600)
    visit task_path(@project, @slug)
    assert_selector "#workspace-summary-heading", wait: 10
    wait_for_live_status

    disclosure = find("details[data-workspace-disclosure-key='advanced']")
    disclosure.find("summary").click
    assert disclosure[:open]
    artifact = find("details[data-artifact-name='brainstorm.md']")
    artifact.find("summary").click
    assert artifact[:open]
    execute_script(<<~JS)
      document.querySelector("details[data-workspace-disclosure-key='advanced'] summary").focus()
      window.scrollTo(0, Math.min(500, document.documentElement.scrollHeight - innerHeight))
    JS
    original_scroll = page.evaluate_script("window.scrollY")

    # An equivalent decision update must not produce a live-region message.
    @folder.join("brainstorm.md").write("draft context\nmore detail\n")
    create_task!(@project, "Equivalent workspace refresh trigger")
    assert_text "more detail", wait: 10
    assert_equal "", page.evaluate_script("document.querySelector('#task-workspace-announcement').textContent")
    assert find("details[data-workspace-disclosure-key='advanced']")[:open]
    assert find("details[data-artifact-name='brainstorm.md']")[:open]
    assert_no_selector "turbo-frame[id^='task-publication-']"
    assert_no_selector "turbo-frame[id^='task-diff-']"
    assert_in_delta original_scroll, page.evaluate_script("window.scrollY"), 2

    brainstorm = stage_dir(@project, "2-brainstorm").join(@slug)
    FileUtils.mv(@folder, brainstorm)
    @folder = brainstorm
    create_task!(@project, "Material workspace refresh trigger")
    assert_selector "#workspace-primary-result[data-primary-artifact='brainstorm.md']", wait: 10
    refute_empty page.evaluate_script(
      "document.querySelector('#task-workspace-announcement').textContent"
    ), "a canonical action change should be announced without relying on attempts/resources"
    assert find("details[data-workspace-disclosure-key='advanced']")[:open]
    assert_equal "advanced",
                 page.evaluate_script("document.activeElement.closest('details')?.dataset.workspaceDisclosureKey")
  end
end
