require "application_system_test_case"

class KanbanBoardTest < ApplicationSystemTestCase
  teardown { StatusBroadcaster.stop! }

  test "operator follows an ordinary hidden summary into the complete archive and task detail" do
    project = create_hive_project!("kanban-archive-app")
    slug = create_task!(project, "Keep the complete archive reachable")
    source = stage_dir(project, "1-inbox").join(slug)
    archived = stage_dir(project, "9-done").join(slug)
    FileUtils.mv(source, archived)
    archived.join("task.md").write("<!-- COMPLETE -->\n")
    Hive::TaskMeta.rewrite(
      archived.to_s,
      completed_at: Time.now.utc - (4 * Hive::ArchiveFilter::SECONDS_PER_DAY)
    )

    sign_in!

    assert_no_selector ".kanban-card[data-task-slug='#{slug}']"
    find(".archive-summary a", text: "… and 1 older archived task (hive archive to view)").click
    assert_current_path archive_path(project:)
    assert_selector "#status-archive [data-task-slug='#{slug}']"

    find("[data-task-slug='#{slug}'] a", text: "Keep the complete archive reachable").click
    assert_current_path task_path(project, slug, source: "archive")
    assert_selector ".task-header", text: "Keep the complete archive reachable"
  end

  test "operator switches between the live board and grid without losing the preference" do
    project = create_hive_project!("kanban-browser-app")
    slug = create_task!(project, "Move through a native board")
    sign_in!

    assert_selector "#status-board"
    assert_selector ".kanban-card", text: "Move through a native board"
    assert_status_refresh_ready

    execute_script(<<~JS)
      document.addEventListener("submit", () => {
        const stream = document.createElement("turbo-stream")
        stream.setAttribute("action", "refresh")
        document.documentElement.appendChild(stream)
      }, { once: true })
      document.addEventListener("turbo:submit-start", () => {
        const stream = document.createElement("turbo-stream")
        stream.setAttribute("action", "refresh")
        document.documentElement.appendChild(stream)
      }, { once: true })
      document.addEventListener("turbo:submit-end", () => {
        setTimeout(() => {
          const stream = document.createElement("turbo-stream")
          stream.setAttribute("action", "refresh")
          document.documentElement.appendChild(stream)
        }, 0)
      }, { once: true })
    JS
    click_status_view("Grid")
    assert_current_path grid_path, wait: 10
    assert_selector "#status-grid .task-row", text: slug
    assert_status_redirect_guard_cleared

    visit root_path
    assert_selector "#status-grid", wait: 5

    click_status_view("Board")
    assert_current_path board_path, wait: 10
    assert_selector "#status-board .kanban-card", text: slug
  end

  test "board remains contained at a mobile viewport" do
    project = create_hive_project!("kanban-#{"unbroken" * 8}")
    create_task!(project, "A deliberately long kanban task title that must stay inside the mobile viewport")
    sign_in!
    page.current_window.resize_to(375, 812)

    assert_selector "#status-board"
    metrics = page.evaluate_script(<<~JS)
      (() => {
        const columns = document.querySelector(".kanban-columns")
        columns.scrollLeft = 120
        return {
          viewport: document.documentElement.clientWidth,
          documentWidth: document.documentElement.scrollWidth,
          boardWidth: document.querySelector("#status-board").scrollWidth,
          columnsClientWidth: columns.clientWidth,
          columnsScrollWidth: columns.scrollWidth,
          columnsScrollLeft: columns.scrollLeft
        }
      })()
    JS
    assert_operator metrics.fetch("documentWidth"), :<=, metrics.fetch("viewport") + 1
    assert_operator metrics.fetch("boardWidth"), :>=, metrics.fetch("viewport") - 30,
                    "the columns should scroll inside the board rather than widening the page"
    assert_operator metrics.fetch("columnsScrollWidth"), :>, metrics.fetch("columnsClientWidth")
    assert_operator metrics.fetch("columnsScrollLeft"), :>, 0
  end

  test "board uses the available width on large screens" do
    project = create_hive_project!("kanban-wide-app")
    create_task!(project, "Use the whole workspace")
    sign_in!
    page.current_window.resize_to(3840, 1400)

    metrics = page.evaluate_script(<<~JS)
      (() => {
        const viewport = document.documentElement.clientWidth
        const main = document.querySelector("main").getBoundingClientRect()
        const topbar = document.querySelector(".topbar-inner").getBoundingClientRect()
        const statusMain = document.querySelector(".status-main").getBoundingClientRect()
        const column = document.querySelector(".kanban-column").getBoundingClientRect()
        return {
          viewport,
          mainWidth: main.width,
          topbarWidth: topbar.width,
          statusMainWidth: statusMain.width,
          columnWidth: column.width
        }
      })()
    JS

    assert_operator metrics.fetch("viewport") - metrics.fetch("mainWidth"), :<=, 80,
                    "the application shell should keep only fluid edge gutters"
    assert_in_delta metrics.fetch("mainWidth"), metrics.fetch("topbarWidth"), 1,
                    "navigation and page content should share the full-width shell"
    assert_operator metrics.fetch("statusMainWidth"), :>, 3_400,
                    "the project rail must leave the rest of a large screen to task content"
    assert_operator metrics.fetch("columnWidth"), :>, 310,
                    "kanban columns should grow after their comfortable minimum instead of staying capped"
  end

  test "project filter survives a view switch" do
    selected_project = create_hive_project!("kanban-filtered-app")
    hidden_project = create_hive_project!("kanban-hidden-app")
    create_task!(selected_project, "Keep this project selected")
    create_task!(hidden_project, "Hide this other project")
    sign_in!

    click_project_filter(selected_project)
    assert_selector ".kanban-band[data-project-name='#{selected_project}']"
    assert_no_selector ".kanban-band[data-project-name='#{hidden_project}']", visible: :all

    click_status_view("Grid")

    assert_current_path grid_path(project: selected_project), wait: 10
    assert_selector "#status-grid .project-section[data-project-name='#{selected_project}']"
    assert_no_selector "#status-grid .project-section[data-project-name='#{hidden_project}']", visible: :all
  end

  test "a refresh deferred during a failed idea submission is replayed" do
    project = create_hive_project!("kanban-refresh-replay-app")
    sign_in!

    execute_script(<<~JS)
      document.querySelector("#composer").dispatchEvent(new CustomEvent("turbo:submit-start", {
        bubbles: true
      }))
    JS
    slug = create_task!(project, "Visible after failed submit")
    execute_script(<<~JS)
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "refresh")
      document.documentElement.appendChild(stream)
    JS
    assert_no_selector ".kanban-card[data-task-slug='#{slug}']", wait: 0

    execute_script(<<~JS)
      document.querySelector("#composer").dispatchEvent(new CustomEvent("turbo:submit-end", {
        bubbles: true,
        detail: { success: false, fetchResponse: { statusCode: 422 } }
      }))
    JS

    assert_selector ".kanban-card[data-task-slug='#{slug}']", wait: 10
  end

  test "live project reordering preserves the focused card and band scroll" do
    focused_project = create_hive_project!("kanban-focused-app")
    moving_project = create_hive_project!("kanban-moving-app")
    focused_slug = create_task!(focused_project, "Keep this action focused")
    disable_daemon!(focused_project)
    sign_in!

    focused_card = find(".kanban-card[data-task-slug='#{focused_slug}']")
    focused_card.find_button("Run brainstorm")
    expected_action = evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".kanban-card[data-task-slug='#{focused_slug}']")
        card.querySelector("button").focus()
        return card.querySelector("form").action
      })()
    JS
    initial_scroll = evaluate_script(<<~JS)
      (() => {
        const columns = document.querySelector(".kanban-band[data-project-name='#{focused_project}'] .kanban-columns")
        columns.scrollLeft = 120
        return columns.scrollLeft
      })()
    JS
    assert_operator initial_scroll, :>, 0

    wait_for_live_status
    create_task!(moving_project, "Move ahead one")
    create_task!(moving_project, "Move ahead two")
    assert_selector ".kanban-band[data-project-name='#{moving_project}'] .kanban-card", count: 2, wait: 10
    project_order = evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("#status-board > .kanban-band"))
        .map((band) => band.dataset.projectName)
    JS
    assert_operator project_order.index(moving_project), :<, project_order.index(focused_project)

    assert_equal expected_action, evaluate_script("document.activeElement.closest('form')?.action")
    final_scroll = evaluate_script(
      "document.querySelector(\".kanban-band[data-project-name='#{focused_project}'] .kanban-columns\").scrollLeft"
    )
    assert_operator final_scroll, :>=, initial_scroll - 1
  end

  test "a focused task follows its card when the live workflow stage changes" do
    project = create_hive_project!("kanban-focused-move-app")
    slug = create_task!(project, "Follow this moving card")
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
    wait_for_status_subscribers(1)
    expected_href = evaluate_script(<<~JS)
      (() => {
        const link = document.querySelector(".kanban-card[data-task-slug='#{slug}'] a")
        link.focus()
        return link.href
      })()
    JS

    FileUtils.mv(stage_dir(project, "1-inbox").join(slug), stage_dir(project, "2-brainstorm").join(slug))
    assert_selector ".kanban-column[data-stage='2-brainstorm'] .kanban-card[data-task-slug='#{slug}']", wait: 10

    assert_equal slug, evaluate_script("document.activeElement.closest('.kanban-card')?.dataset.taskSlug")
    assert_equal expected_href, evaluate_script("document.activeElement.href")
  end

  test "a live refresh cannot abort a board task action" do
    project = create_hive_project!("kanban-action-race-app")
    slug = create_task!(project, "Queue this exactly once")
    disable_daemon!(project)
    sign_in!
    dispatches = Queue.new
    replacement = lambda do |**attributes|
      dispatches << attributes
      Hive::Bot::DispatchRequestWriter::DispatchReference.new(
        request_id: "system-test-request", attempt_id: nil, state: "queued",
        status: :queued, argv: attributes.fetch(:argv)
      )
    end

    execute_script(<<~JS)
      document.addEventListener("turbo:submit-start", () => {
        const stream = document.createElement("turbo-stream")
        stream.setAttribute("action", "refresh")
        document.documentElement.appendChild(stream)
      }, { once: true })
    JS
    with_replaced_singleton_method(Hive::Bot::DispatchRequestWriter, :dispatch!, replacement) do
      within(".kanban-card[data-task-slug='#{slug}']") { click_button "Run brainstorm" }
      assert_selector ".flash-notice", text: "Queued for the daemon", wait: 10
    end
    assert_equal 1, dispatches.size
    assert_equal slug, dispatches.pop.fetch(:slug)
  end

  test "cancelling a task confirmation does not block later live refreshes" do
    project = create_hive_project!("task-cancelled-confirm-app")
    slug = create_task!(project, "Keep refreshing after cancel")
    sign_in!
    visit task_path(project, slug)
    assert_status_refresh_ready

    find(".advanced summary").click
    within(".advanced") { assert_button "Reject", disabled: false }
    dismiss_confirm do
      within(".advanced") { click_button "Reject" }
    end

    stage_dir(project, "1-inbox").join(slug, "brainstorm.md").write("# Visible after cancellation\n")
    execute_script(<<~JS)
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "refresh")
      document.documentElement.appendChild(stream)
    JS

    assert_selector ".artifact", text: "brainstorm.md", wait: 10
  end

  test "a Cable reconnect catches up after a missed status broadcast" do
    with_slow_status_feed do |feed|
      project = create_hive_project!("kanban-cable-reconnect-app")
      sign_in!
      assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
      rendered_token = status_page_token

      execute_script(<<~JS)
        window.testStatusLayout = document.querySelector("[data-controller~='status-refresh']")
        window.testStatusLayout.remove()
      JS
      wait_for_status_subscribers(0)
      slug = create_task!(project, "Visible after reconnect")
      feed.send(:publish, feed.snapshot)
      refute feed.current_version?(rendered_token)

      with_status_catch_up_observer do |catch_ups|
        execute_script(<<~JS)
          document.body.appendChild(window.testStatusLayout)
        JS

        assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
        catch_up = Timeout.timeout(10) { catch_ups.pop }
        assert_equal rendered_token, catch_up.fetch("status_version"),
                     "the restored page must send the exact token it rendered"
        assert_selector ".kanban-card[data-task-slug='#{slug}']", wait: 10
      end
    end
  end

  test "a restored Board catches up after its cached Cable source reconnects" do
    with_slow_status_feed do |feed|
      project = create_hive_project!("kanban-history-reconnect-app")
      original_slug = create_task!(project, "Open this before history restore")
      sign_in!
      assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
      board_token = status_page_token

      find(".kanban-card[data-task-slug='#{original_slug}'] .kanban-card-heading a").click
      assert_current_path task_path(project, original_slug)
      execute_script("document.querySelector('#status-stream-owner').remove()")
      wait_for_status_subscribers(0)
      restored_slug = create_task!(project, "Visible after history restore")
      feed.send(:publish, feed.snapshot)
      refute feed.current_version?(board_token)

      with_status_catch_up_observer do |catch_ups|
        page.go_back

        assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
        catch_up = Timeout.timeout(10) { catch_ups.pop }
        assert_equal board_token, catch_up.fetch("status_version")
        assert_selector ".kanban-card[data-task-slug='#{restored_slug}']", wait: 10
      end
    end
  end

  test "fresh Turbo navigation does not issue a reconnect refresh request" do
    with_slow_status_feed do |feed|
      project = create_hive_project!("kanban-navigation-request-app")
      slug = create_task!(project, "Open with one request")
      sign_in!
      assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
      task_pathname = task_path(project, slug)

      start_status_navigation_request_tracking
      with_status_catch_up_observer do |catch_ups|
        find(".kanban-card[data-task-slug='#{slug}'] .kanban-card-heading a").click
        assert_current_path task_pathname, wait: 10
        assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
        catch_up = Timeout.timeout(10) { catch_ups.pop }
        checked_token = catch_up.fetch("status_version")

        assert feed.current_version?(checked_token),
               "the server must complete the current-token decision before request counting"
        refute catch_up.fetch("refresh_attempted")
      end
      requests = status_request_count_after_quiet(task_pathname)

      assert_equal 1, requests,
                   "a current version handshake must not turn one navigation into a second refresh GET"
    end
  end

  test "a lagging Cable worker requests at most one refresh for a fresh page token" do
    with_slow_status_feed do
      project = create_hive_project!("kanban-worker-lag-app")
      slug = create_task!(project, "Open across mismatched workers")
      sign_in!
      assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
      task_pathname = task_path(project, slug)

      start_status_navigation_request_tracking
      with_replaced_singleton_method(StatusBroadcaster, :current_version?, ->(_token) { false }) do
        with_status_catch_up_observer do |catch_ups|
          find(".kanban-card[data-task-slug='#{slug}'] .kanban-card-heading a").click
          assert_current_path task_pathname, wait: 10

          first = Timeout.timeout(10) { catch_ups.pop }
          page.document.synchronize(10) do
            loads = evaluate_script("window.statusNavigationLoads")
            raise Capybara::ElementNotFound, "targeted catch-up refresh did not finish" if loads < 2
          end
          execute_script(<<~JS)
            const source = document.querySelector("#status-stream-source")
            const lifecycle = source.statusOwner
            lifecycle.subscriptionConnected(lifecycle.currentAttempt)
          JS
          second = Timeout.timeout(10) { catch_ups.pop }
          assert_equal first.fetch("status_version"), second.fetch("status_version")
          refute first.fetch("refresh_attempted")
          assert second.fetch("refresh_attempted"),
                 "the permanent stream source must remember the targeted refresh"
        end
      end
      requests = status_request_count_after_quiet(task_pathname)

      assert_equal 2, requests,
                   "a lagging worker may reconcile once but must not create an unbounded GET loop"
    end
  end

  test "a lagging Cable worker stays bounded when reconciliation changes the page token" do
    with_slow_status_feed do
      project = create_hive_project!("kanban-changing-token-app")
      slug = create_task!(project, "Reconcile across changing tokens")
      original_snapshot = StatusBroadcaster.method(:snapshot_with_version)
      original_current_snapshot = StatusBroadcaster.method(:current_page_snapshot)
      sequence = 0
      sequence_mutex = Mutex.new
      changing_version = lambda do |page_snapshot|
        version = sequence_mutex.synchronize do
          sequence += 1
          "render-token-#{sequence}"
        end
        StatusBroadcaster::PageSnapshot.new(
          payload: page_snapshot.payload,
          version: version,
          availability: page_snapshot.availability,
          last_success_at: page_snapshot.last_success_at,
          error: page_snapshot.error
        )
      end
      changing_snapshot = -> { changing_version.call(original_snapshot.call) }
      changing_current_snapshot = lambda do
        changing_version.call(original_current_snapshot.call || original_snapshot.call)
      end

      with_replaced_singleton_method(StatusBroadcaster, :snapshot_with_version, changing_snapshot) do
        with_replaced_singleton_method(
          StatusBroadcaster, :current_page_snapshot, changing_current_snapshot
        ) do
          sign_in!
          assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
          task_pathname = task_path(project, slug)

          start_status_navigation_request_tracking
          with_replaced_singleton_method(StatusBroadcaster, :current_version?, ->(_token) { false }) do
            with_status_catch_up_observer do |catch_ups|
              find(".kanban-card[data-task-slug='#{slug}'] .kanban-card-heading a").click
              assert_current_path task_pathname, wait: 10

              first = Timeout.timeout(10) { catch_ups.pop }
              page.document.synchronize(10) do
                loads = evaluate_script("window.statusNavigationLoads")
                raise Capybara::ElementNotFound, "targeted catch-up refresh did not finish" if loads < 2
              end
              execute_script(<<~JS)
                const source = document.querySelector("#status-stream-source")
                const lifecycle = source.statusOwner
                lifecycle.subscriptionConnected(lifecycle.currentAttempt)
              JS
              second = Timeout.timeout(10) { catch_ups.pop }

              refute_equal first.fetch("status_version"), second.fetch("status_version"),
                           "the reconciliation response must exercise a different render token"
              refute first.fetch("refresh_attempted")
              assert second.fetch("refresh_attempted"),
                     "the same-URL refresh-cycle latch must not depend on token equality"
            end
          end
          requests = status_request_count_after_quiet(task_pathname)

          assert_equal 2, requests,
                       "a changing HTTP token must not let a lagging worker start another refresh GET"
        end
      end
    end
  end

  test "a real Cable disconnect releases the catch-up attempt for later recovery" do
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    result = evaluate_script(<<~JS)
      (() => {
        const source = document.querySelector("#status-stream-source")
        const lifecycle = source.statusOwner
        const attempt = lifecycle.currentAttempt
        const originalPerform = attempt.subscription.perform
        const performed = []
        source.catchUpRefresh = {
          token: source.statusVersion,
          location: source.statusLocation
        }
        attempt.subscription.perform = (action, data) => {
          performed.push([action, data])
          return true
        }

        try {
          attempt.subscription.disconnected({ willAttemptReconnect: true })
          attempt.subscription.connected({ reconnected: true })
          return {
            catchUpRefreshCleared: !source.catchUpRefresh,
            performed
          }
        } finally {
          attempt.subscription.perform = originalPerform
        }
      })()
    JS

    assert result.fetch("catchUpRefreshCleared")
    assert_equal false, result.dig("performed", 0, 1, "refresh_attempted"),
                 "a later real reconnect must be eligible to recover a now-stale page"
  end

  test "a permanent source does not carry a catch-up attempt to another URL" do
    with_slow_status_feed do
      project = create_hive_project!("kanban-catch-up-location-app")
      slug = create_task!(project, "Open after a Board catch-up")
      sign_in!
      assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
      board_token = status_page_token
      execute_script(<<~JS)
        const source = document.querySelector("#status-stream-source")
        source.catchUpRefresh = {
          token: source.statusVersion,
          location: source.statusLocation
        }
      JS

      with_status_catch_up_observer do |catch_ups|
        find(".kanban-card[data-task-slug='#{slug}'] .kanban-card-heading a").click
        assert_current_path task_path(project, slug), wait: 10
        assert_equal board_token, status_page_token,
                     "route-only navigation should preserve the semantic status token"
        catch_up = Timeout.timeout(10) { catch_ups.pop }

        refute catch_up.fetch("refresh_attempted"),
               "an attempt from the Board URL must not suppress later task-page recovery"
      end

      with_status_catch_up_observer do |catch_ups|
        page.go_back
        assert_current_path root_path, wait: 10
        assert_equal board_token, status_page_token
        catch_up = Timeout.timeout(10) { catch_ups.pop }

        refute catch_up.fetch("refresh_attempted"),
               "returning to the original URL must not revive its consumed attempt"
      end
    end
  end

  test "navigation consumes a catch-up handoff before the next connection settles" do
    project = create_hive_project!("kanban-unconfirmed-navigation-app")
    slug = create_task!(project, "Navigate before Cable settles")
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    result = evaluate_script(<<~JS, task_path(project, slug))
      (async (taskPath) => {
        const liveSource = document.querySelector("#status-stream-source")
        const originalLocation = `${window.location.pathname}${window.location.search}`
        const pageToken = document.querySelector("[data-status-version]").dataset.statusVersion
        const owner = document.createElement("div")
        owner.dataset.statusVersion = pageToken
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", liveSource.getAttribute("channel"))
        source.setAttribute("signed-stream-name", liveSource.getAttribute("signed-stream-name"))
        source.catchUpRefresh = { token: pageToken, location: originalLocation }
        source.createConsumer = () => new Promise(() => {})
        owner.appendChild(source)

        try {
          history.replaceState({}, "", taskPath)
          document.body.appendChild(owner)
          const result = {
            catchUpRefreshCleared: !source.catchUpRefresh
          }
          history.replaceState({}, "", originalLocation)
          owner.remove()
          return result
        } finally {
          history.replaceState({}, "", originalLocation)
          owner.remove()
        }
      })(arguments[0])
    JS

    assert result.fetch("catchUpRefreshCleared")
  end

  test "a failed intermediate catch-up cannot revive an older URL handoff" do
    project = create_hive_project!("kanban-failed-navigation-app")
    slug = create_task!(project, "Return after a failed catch-up")
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    result = evaluate_script(<<~JS, task_path(project, slug))
      (async (taskPath) => {
        const liveSource = document.querySelector("#status-stream-source")
        const originalLocation = `${window.location.pathname}${window.location.search}`
        const pageToken = document.querySelector("[data-status-version]").dataset.statusVersion
        const performed = []
        const subscriptions = []
        const fakeConsumer = {
          disconnect() {},
          subscriptions: {
            subscriptions,
            create(_channel, mixin) {
              const subscription = {
                unsubscribe() {
                  const index = subscriptions.indexOf(subscription)
                  if (index >= 0) subscriptions.splice(index, 1)
                },
                perform(_action, data) {
                  performed.push(data.refresh_attempted)
                  return false
                }
              }
              subscriptions.push(subscription)
              queueMicrotask(() => mixin.connected())
              return subscription
            }
          }
        }
        const owner = document.createElement("div")
        owner.dataset.statusVersion = pageToken
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", liveSource.getAttribute("channel"))
        source.setAttribute("signed-stream-name", liveSource.getAttribute("signed-stream-name"))
        source.catchUpRefresh = { token: pageToken, location: originalLocation }
        owner.appendChild(source)

        try {
          source.createConsumer = async () => fakeConsumer
          history.replaceState({}, "", taskPath)
          document.body.appendChild(owner)
          await new Promise((resolve) => setTimeout(resolve, 0))
          history.replaceState({}, "", originalLocation)
          const lifecycle = source.statusOwner
          lifecycle.subscriptionConnected(lifecycle.currentAttempt)

          return {
            markerCleared: !source.catchUpRefresh,
            performed
          }
        } finally {
          history.replaceState({}, "", originalLocation)
          owner.remove()
        }
      })(arguments[0])
    JS

    assert result.fetch("markerCleared")
    assert_equal [ false, false ], result.fetch("performed"),
                 "neither the intermediate attempt nor the return may reuse the old latch"
  end

  test "a source-less navigation cannot restore a cached catch-up handoff" do
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    execute_script(<<~JS)
      const source = document.querySelector("#status-stream-source")
      source.catchUpRefresh = {
        token: source.statusVersion,
        location: source.statusLocation
      }
    JS

    click_link "Repos"
    assert_current_path repos_path, wait: 10
    assert_no_selector "#status-stream-source", visible: :all

    with_status_catch_up_observer do |catch_ups|
      page.go_back
      assert_current_path root_path, wait: 10
      assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
      catch_up = Timeout.timeout(10) { catch_ups.pop }

      refute catch_up.fetch("refresh_attempted"),
             "a Turbo snapshot restored after a source-less route must not revive the old latch"
    end
  end

  test "a task reconnect catches up after a missed status broadcast" do
    with_slow_status_feed do |feed|
      project = create_hive_project!("task-cable-reconnect-app")
      slug = create_task!(project, "Keep this task current")
      sign_in!
      visit task_path(project, slug)
      assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
      rendered_token = status_page_token

      execute_script(<<~JS)
        window.testTaskStatusOwner = document.querySelector("#status-stream-owner")
        window.testTaskStatusOwner.remove()
      JS
      wait_for_status_subscribers(0)
      stage_dir(project, "1-inbox").join(slug, "brainstorm.md").write("# Arrived while disconnected\n")
      feed.send(:publish, feed.snapshot)
      refute feed.current_version?(rendered_token)

      with_status_catch_up_observer do |catch_ups|
        execute_script(<<~JS)
          document.body.appendChild(window.testTaskStatusOwner)
        JS

        assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
        catch_up = Timeout.timeout(10) { catch_ups.pop }
        assert_equal rendered_token, catch_up.fetch("status_version")
        assert_selector ".artifact", text: "brainstorm.md", wait: 10
      end
    end
  end

  private

  def with_slow_status_feed
    StatusBroadcaster.stop!
    feed = Hive::Web::StatusFeed.new(interval: 60)
    StatusBroadcaster.feed = feed
    yield feed
  ensure
    StatusBroadcaster.stop!
    StatusBroadcaster.feed = nil
  end

  def with_status_catch_up_observer
    original = StatusChannel.instance_method(:catch_up)
    completed = Queue.new
    StatusChannel.define_method(:catch_up) do |data|
      result = original.bind_call(self, data)
      completed << data.to_h
      result
    end
    yield completed
  ensure
    StatusChannel.define_method(:catch_up, original) if original
  end

  def wait_for_status_subscribers(expected)
    Timeout.timeout(10) do
      sleep 0.01 until StatusBroadcaster.instance_variable_get(:@subscriber_count).to_i == expected
    end
  end

  def status_page_token
    find("[data-status-version]", visible: :all)["data-status-version"]
  end

  def start_status_navigation_request_tracking
    execute_script(<<~JS)
      window.statusNavigationRequests = []
      window.statusNavigationLoads = 0
      document.addEventListener("turbo:before-fetch-request", (event) => {
        window.statusNavigationRequests.push(new URL(event.detail.url).pathname)
      })
      document.addEventListener("turbo:load", () => { window.statusNavigationLoads += 1 })
    JS
  end

  def status_request_count_after_quiet(pathname)
    evaluate_script(<<~JS)
      (async () => {
        const pathname = #{pathname.to_json}
        const countRequests = () => window.statusNavigationRequests
          .filter((path) => path === pathname).length
        let count = countRequests()
        let quietSince = performance.now()

        // Turbo debounces refresh visits for 150 ms. Requiring 500 ms with no
        // new matching request makes the assertion observe any queued refresh,
        // and restarts the window whenever one arrives.
        while (performance.now() - quietSince < 500) {
          await new Promise((resolve) => setTimeout(resolve, 25))
          const nextCount = countRequests()
          if (nextCount !== count) {
            count = nextCount
            quietSince = performance.now()
          }
        }

        return count
      })()
    JS
  end

  def click_project_filter(name)
    execute_script(<<~JS, name)
      const name = arguments[0]
      const link = Array.from(document.querySelectorAll("[data-project-filter-name-param]"))
        .find((candidate) => candidate.dataset.projectFilterNameParam === name)
      if (!link) throw new Error(`project filter not found: ${name}`)
      link.click()
    JS
  end

  def click_status_view(name)
    execute_script(<<~JS, name)
      const name = arguments[0]
      const button = Array.from(document.querySelectorAll(".status-view-switch button"))
        .find((candidate) => candidate.textContent.trim() === name)
      if (!button) throw new Error(`status view not found: ${name}`)
      button.click()
    JS
  end

  def assert_status_refresh_ready
    page.document.synchronize(10) do
      ready = evaluate_script(<<~JS)
        (() => {
          const element = document.querySelector("[data-controller~='status-refresh']")
          return Boolean(element && window.Stimulus?.getControllerForElementAndIdentifier(element, "status-refresh"))
        })()
      JS
      raise Capybara::ElementNotFound, "status-refresh controller did not connect" unless ready
    end
  end

  def assert_status_redirect_guard_cleared
    page.document.synchronize(10) do
      guarded = evaluate_script(
        'document.documentElement.hasAttribute("status-refresh-redirect-destination")'
      )
      if guarded
        destination = evaluate_script(
          'document.documentElement.getAttribute("status-refresh-redirect-destination") || ""'
        )
        raise Capybara::ElementNotFound,
              "status redirect guard did not clear (destination=#{destination.inspect}, current=#{page.current_url.inspect})"
      end
    end
  end

  def disable_daemon!(project)
    path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project, ".hive-state", "config.yml")
    data = YAML.safe_load_file(path) || {}
    data["daemon"] = (data["daemon"] || {}).merge("enabled" => false)
    File.write(path, data.to_yaml)
  end
end
