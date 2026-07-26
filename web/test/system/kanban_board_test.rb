require "application_system_test_case"

class KanbanBoardTest < ApplicationSystemTestCase
  teardown { StatusBroadcaster.stop! }

  test "operator switches between the live board and grid without losing the preference" do
    project = create_hive_project!("kanban-browser-app")
    slug = create_task!(project, "Move through a native board")
    visit dev_login_path(as: "alice")

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
    visit dev_login_path(as: "alice")
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

  test "project filter survives a view switch" do
    selected_project = create_hive_project!("kanban-filtered-app")
    hidden_project = create_hive_project!("kanban-hidden-app")
    create_task!(selected_project, "Keep this project selected")
    create_task!(hidden_project, "Hide this other project")
    visit dev_login_path(as: "alice")

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
    visit dev_login_path(as: "alice")

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
    visit dev_login_path(as: "alice")

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
    visit dev_login_path(as: "alice")
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
    visit dev_login_path(as: "alice")
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
    visit dev_login_path(as: "alice")
    visit task_path(project, slug)
    assert_status_refresh_ready

    find(".advanced summary").click
    dismiss_confirm { within(".advanced") { click_button "Reject" } }

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
      visit dev_login_path(as: "alice")
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
      visit dev_login_path(as: "alice")
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
      visit dev_login_path(as: "alice")
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
      visit dev_login_path(as: "alice")
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
            source.subscriptionConnected(source.statusConnection)
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
      sequence = 0
      sequence_mutex = Mutex.new
      changing_snapshot = lambda do
        page_snapshot = original_snapshot.call
        version = sequence_mutex.synchronize do
          sequence += 1
          "render-token-#{sequence}"
        end
        StatusBroadcaster::PageSnapshot.new(payload: page_snapshot.payload, version:)
      end

      with_replaced_singleton_method(StatusBroadcaster, :snapshot_with_version, changing_snapshot) do
        visit dev_login_path(as: "alice")
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
              source.subscriptionConnected(source.statusConnection)
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

  test "a real Cable disconnect releases the catch-up attempt for later recovery" do
    visit dev_login_path(as: "alice")
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    result = evaluate_script(<<~JS)
      (() => {
        const source = document.querySelector("#status-stream-source")
        const connection = source.statusConnection
        const originalPerform = connection.subscription.perform
        const performed = []
        source.catchUpRefresh = {
          token: source.statusVersion,
          location: source.statusLocation
        }
        connection.subscription.perform = (action, data) => {
          performed.push([action, data])
          return true
        }

        try {
          connection.subscription.disconnected()
          connection.subscription.connected()
          return {
            catchUpRefreshCleared: !source.catchUpRefresh,
            performed
          }
        } finally {
          connection.subscription.perform = originalPerform
        }
      })()
    JS

    assert result.fetch("catchUpRefreshCleared")
    assert_equal false, result.dig("performed", 0, 1, "refresh_attempted"),
                 "a later real reconnect must be eligible to recover a now-stale page"
  end

  test "DOM teardown during reconnect waits for the current confirmation" do
    visit dev_login_path(as: "alice")
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
    wait_for_status_subscribers(1)

    retained = evaluate_script(<<~JS)
      (() => {
        const source = document.querySelector("#status-stream-source")
        const owner = source.closest("[data-status-version]")
        const connection = source.statusConnection
        const subscription = connection.subscription
        subscription.disconnected()
        window.testReconnectingStatusSubscription = subscription
        owner.remove()
        return subscription.consumer.subscriptions.subscriptions.includes(subscription)
      })()
    JS

    assert retained,
           "a previously confirmed handle must stay local until its new transport confirms"
    execute_script("window.testReconnectingStatusSubscription.connected()")
    wait_for_status_subscribers(0)
  ensure
    execute_script("window.testReconnectingStatusSubscription?.unsubscribe?.()") if page&.current_url
  end

  test "a permanent source does not carry a catch-up attempt to another URL" do
    with_slow_status_feed do
      project = create_hive_project!("kanban-catch-up-location-app")
      slug = create_task!(project, "Open after a Board catch-up")
      visit dev_login_path(as: "alice")
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
    visit dev_login_path(as: "alice")
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    result = evaluate_script(<<~JS, task_path(project, slug))
      (async (taskPath) => {
        const { cable } = await import("@hotwired/turbo-rails")
        const liveSource = document.querySelector("#status-stream-source")
        const originalConsumer = await cable.getConsumer()
        const originalLocation = `${window.location.pathname}${window.location.search}`
        const pageToken = document.querySelector("[data-status-version]").dataset.statusVersion
        let releaseConsumer
        const delayedConsumer = new Promise((resolve) => { releaseConsumer = resolve })
        const owner = document.createElement("div")
        owner.dataset.statusVersion = pageToken
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", liveSource.getAttribute("channel"))
        source.setAttribute("signed-stream-name", liveSource.getAttribute("signed-stream-name"))
        source.catchUpRefresh = { token: pageToken, location: originalLocation }
        owner.appendChild(source)

        try {
          cable.setConsumer(delayedConsumer)
          history.replaceState({}, "", taskPath)
          document.body.appendChild(owner)
          const result = {
            catchUpRefreshCleared: !source.catchUpRefresh
          }
          history.replaceState({}, "", originalLocation)
          owner.remove()
          releaseConsumer(originalConsumer)
          await Promise.resolve()
          return result
        } finally {
          history.replaceState({}, "", originalLocation)
          owner.remove()
          releaseConsumer?.(originalConsumer)
          cable.setConsumer(originalConsumer)
        }
      })(arguments[0])
    JS

    assert result.fetch("catchUpRefreshCleared")
  end

  test "a failed intermediate catch-up cannot revive an older URL handoff" do
    project = create_hive_project!("kanban-failed-navigation-app")
    slug = create_task!(project, "Return after a failed catch-up")
    visit dev_login_path(as: "alice")
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    result = evaluate_script(<<~JS, task_path(project, slug))
      (async (taskPath) => {
        const { cable } = await import("@hotwired/turbo-rails")
        const liveSource = document.querySelector("#status-stream-source")
        const originalConsumer = await cable.getConsumer()
        const originalLocation = `${window.location.pathname}${window.location.search}`
        const pageToken = document.querySelector("[data-status-version]").dataset.statusVersion
        const performed = []
        const subscriptions = []
        const fakeConsumer = {
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
          cable.setConsumer(fakeConsumer)
          history.replaceState({}, "", taskPath)
          document.body.appendChild(owner)
          await new Promise((resolve) => setTimeout(resolve, 0))
          history.replaceState({}, "", originalLocation)
          source.subscriptionConnected(source.statusConnection)

          return {
            markerCleared: !source.catchUpRefresh,
            performed
          }
        } finally {
          history.replaceState({}, "", originalLocation)
          owner.remove()
          cable.setConsumer(originalConsumer)
        }
      })(arguments[0])
    JS

    assert result.fetch("markerCleared")
    assert_equal [ false, false ], result.fetch("performed"),
                 "neither the intermediate attempt nor the return may reuse the old latch"
  end

  test "a source-less navigation cannot restore a cached catch-up handoff" do
    visit dev_login_path(as: "alice")
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
      visit dev_login_path(as: "alice")
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

  test "a pending status subscription is cancelled across disconnect and reconnect" do
    visit dev_login_path(as: "alice")

    result = evaluate_script(<<~JS)
      (async () => {
        const { cable } = await import("@hotwired/turbo-rails")
        const originalConsumer = await cable.getConsumer()
        let releaseConsumer
        const delayedConsumer = new Promise((resolve) => { releaseConsumer = resolve })
        let created = 0
        let unsubscribed = 0
        const performed = []
        const owner = document.createElement("div")
        owner.dataset.statusVersion = "7"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-token")
        owner.appendChild(source)
        try {
          cable.setConsumer(delayedConsumer)
          document.body.appendChild(owner)
          owner.remove()
          document.body.appendChild(owner)

          releaseConsumer({
            subscriptions: {
              create(_channel, mixin) {
                created += 1
                const subscription = {
                  unsubscribe() { unsubscribed += 1 },
                  perform(action, data) {
                    performed.push([action, data.status_version])
                    if (performed.length === 1) queueMicrotask(() => mixin.connected())
                    return performed.length > 1
                  }
                }
                queueMicrotask(() => mixin.connected())
                return subscription
              }
            }
          })
          await new Promise((resolve) => setTimeout(resolve, 0))
          const afterReconnect = { created, unsubscribed, performed }

          owner.remove()
          await new Promise((resolve) => setTimeout(resolve, 0))
          return { afterReconnect, afterDisconnect: { created, unsubscribed } }
        } finally {
          owner.remove()
          cable.setConsumer(originalConsumer)
        }
      })()
    JS

    assert_equal({ "created" => 1, "unsubscribed" => 0,
                   "performed" => [ [ "catch_up", "7" ], [ "catch_up", "7" ] ] },
                 result.fetch("afterReconnect"),
                 "a stale pending setup must be discarded before it creates a subscription")
    assert_equal({ "created" => 1, "unsubscribed" => 1 }, result.fetch("afterDisconnect"),
                 "the final DOM owner leaving must unsubscribe the final handle")
  end

  test "DOM teardown waits for Cable confirmation before server unsubscribe" do
    visit dev_login_path(as: "alice")
    visit repos_path
    assert_no_selector "#status-stream-source", visible: :all
    wait_for_status_subscribers(0)

    entered_subscription = Queue.new
    release_subscription = Queue.new
    connected = Queue.new
    disconnected = Queue.new
    released = false
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])
    original_verifier = StatusChannel.instance_method(:verified_stream_name_from_params)
    blocked_verifier = proc do
      entered_subscription << true
      release_subscription.pop
      original_verifier.bind_call(self)
    end

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, -> { connected << true }) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, -> { disconnected << true }) do
        with_replaced_instance_method(StatusChannel, :verified_stream_name_from_params, blocked_verifier) do
          execute_script(<<~JS, signed_name)
            const owner = document.createElement("div")
            owner.id = "pending-status-owner"
            owner.dataset.statusVersion = "pending-token"
            const source = document.createElement("hive-status-stream-source")
            source.setAttribute("channel", "StatusChannel")
            source.setAttribute("signed-stream-name", arguments[0])
            owner.appendChild(source)
            document.body.appendChild(owner)
          JS
          Timeout.timeout(10) { entered_subscription.pop }

          execute_script("document.querySelector('#pending-status-owner').remove()")
          release_subscription << true
          released = true

          Timeout.timeout(10) { connected.pop }
          Timeout.timeout(10) { disconnected.pop }
        end
      end
    end

    assert connected.empty?
    assert disconnected.empty?
  ensure
    release_subscription << true if release_subscription && !released
    execute_script("document.querySelector('#pending-status-owner')?.remove()") if page&.current_url
  end

  test "a detached source has bounded cleanup when confirmation never arrives" do
    visit dev_login_path(as: "alice")
    visit repos_path
    wait_for_status_subscribers(0)

    result = evaluate_script(<<~JS)
      (async () => {
        const { cable } = await import("@hotwired/turbo-rails")
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalConsumer = await cable.getConsumer()
        const originalDelay = sourceClass.pendingReleaseDelay
        const subscriptions = []
        let disconnects = 0
        let socketCloses = 0
        let unsubscribes = 0
        const fakeConsumer = {
          connection: { webSocket: { close() { socketCloses += 1 } } },
          subscriptions: {
            subscriptions,
            create() {
              const subscription = {
                identifier: "never-confirmed-status",
                consumer: fakeConsumer,
                perform() { return true },
                unsubscribe() {
                  unsubscribes += 1
                  const index = subscriptions.indexOf(subscription)
                  if (index >= 0) subscriptions.splice(index, 1)
                }
              }
              subscriptions.push(subscription)
              return subscription
            }
          },
          disconnect() { disconnects += 1 }
        }
        const owner = document.createElement("div")
        owner.dataset.statusVersion = "pending-token"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-token")
        owner.appendChild(source)

        try {
          sourceClass.pendingReleaseDelay = 0
          cable.setConsumer(fakeConsumer)
          document.body.appendChild(owner)
          const setupDeadline = performance.now() + 1_000
          while (!source.statusConnection?.subscription && performance.now() < setupDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const connection = source.statusConnection
          if (!connection?.subscription) throw new Error("pending subscription was not created")

          owner.remove()
          const cleanupDeadline = performance.now() + 1_000
          while (subscriptions.length > 0 && performance.now() < cleanupDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }

          return {
            disconnects,
            socketCloses,
            unsubscribes,
            registered: subscriptions.length,
            pendingTimer: Boolean(connection.pendingReleaseTimer),
            retryTimer: Boolean(connection.retryTimer)
          }
        } finally {
          owner.remove()
          sourceClass.pendingReleaseDelay = originalDelay
          cable.setConsumer(originalConsumer)
        }
      })()
    JS

    assert_equal({
      "disconnects" => 1,
      "socketCloses" => 1,
      "unsubscribes" => 1,
      "registered" => 0,
      "pendingTimer" => false,
      "retryTimer" => false
    }, result)
  end

  test "a server startup rejection retries the live source" do
    visit dev_login_path(as: "alice")
    visit repos_path
    wait_for_status_subscribers(0)
    original_delay = evaluate_script(<<~JS)
      (() => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const delay = sourceClass.retryDelay
        sourceClass.retryDelay = 0
        return delay
      })()
    JS
    attempts = 0
    disconnected = 0
    counter_mutex = Mutex.new
    connect = lambda do
      attempt = counter_mutex.synchronize { attempts += 1 }
      raise ThreadError, "cannot create broadcaster" if attempt == 1
    end
    disconnect = -> { counter_mutex.synchronize { disconnected += 1 } }

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, connect) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, disconnect) do
        visit root_path
        assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
        assert_equal 2, counter_mutex.synchronize { attempts }

        visit repos_path
        page.document.synchronize(10) do
          count = counter_mutex.synchronize { disconnected }
          raise Capybara::ElementNotFound, "recovered subscription did not release" unless count == 1
        end
      end
    end

    assert_equal 1, counter_mutex.synchronize { disconnected }
  ensure
    execute_script(<<~JS, original_delay) if page&.current_url && original_delay
      customElements.get("hive-status-stream-source").retryDelay = arguments[0]
    JS
  end

  test "a deferred adapter failure reconnects the live source" do
    visit dev_login_path(as: "alice")
    visit repos_path
    wait_for_status_subscribers(0)
    adapter = ActionCable.server.pubsub
    original_subscribe = adapter.method(:subscribe)
    attempts = 0
    counter_mutex = Mutex.new
    subscribe = lambda do |broadcasting, *args, &block|
      attempt = counter_mutex.synchronize { attempts += 1 } if broadcasting == StatusBroadcaster::CHANNEL
      if attempt == 1
        raise ActiveRecord::ConnectionNotEstablished, "cable database unavailable"
      end

      original_subscribe.call(broadcasting, *args, &block)
    end

    with_replaced_singleton_method(adapter, :subscribe, subscribe) do
      visit root_path
      # Action Cable's first reconnect poll is intentionally jittered between
      # 6 and 12 seconds. Allow that production cadence to run instead of
      # turning this integration test into a race against its default wait.
      assert_selector "#status-stream-source[connected]", visible: :all, wait: 20
      assert_operator counter_mutex.synchronize { attempts }, :>=, 2
      wait_for_status_subscribers(1)

      visit repos_path
      wait_for_status_subscribers(0)
    end
  end

  test "a status source retries after asynchronous consumer setup rejects" do
    visit dev_login_path(as: "alice")

    with_status_catch_up_observer do |catch_ups|
      result = evaluate_script(<<~JS)
        (async () => {
          const { cable } = await import("@hotwired/turbo-rails")
          const sourceClass = customElements.get("hive-status-stream-source")
          const liveSource = document.querySelector("#status-stream-source")
          const originalConsumer = await cable.getConsumer()
          const originalRetryDelay = sourceClass.retryDelay
          const owner = document.createElement("div")
          owner.dataset.statusVersion = `retry-${crypto.randomUUID()}`
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", liveSource.getAttribute("channel"))
          source.setAttribute("signed-stream-name", liveSource.getAttribute("signed-stream-name"))
          source.catchUpRefresh = { token: owner.dataset.statusVersion, location: source.statusLocation }
          owner.appendChild(source)
          let recoveredConsumer

          const cleanup = () => {
            owner.remove()
            recoveredConsumer?.disconnect()
            sourceClass.retryDelay = originalRetryDelay
            cable.setConsumer(originalConsumer)
            delete window.hiveStatusRetryCleanup
          }

          try {
            sourceClass.retryDelay = 0
            cable.setConsumer(Promise.reject(new Error("consumer setup failed")))
            const connected = new Promise((resolve, reject) => {
              const deadline = setTimeout(() => reject(new Error("status retry did not connect")), 5_000)
              const observer = new MutationObserver(() => {
                if (!source.hasAttribute("connected")) return

                clearTimeout(deadline)
                observer.disconnect()
                resolve(true)
              })
              observer.observe(source, { attributes: true, attributeFilter: ["connected"] })
            })
            document.body.appendChild(owner)
            await connected
            recoveredConsumer = await cable.getConsumer()
            window.hiveStatusRetryCleanup = cleanup

            return { connected: source.hasAttribute("connected"), pageToken: owner.dataset.statusVersion }
          } catch (error) {
            cleanup()
            throw error
          }
        })()
      JS

      assert result.fetch("connected")
      catch_up = wait_for_status_catch_up(catch_ups, result.fetch("pageToken"))
      assert_equal result.fetch("pageToken"), catch_up.fetch("status_version"),
                   "application code must clear the poisoned cache and complete a real catch-up"
    end
  ensure
    cleanup_status_retry_fixture
  end

  test "a status source removes a partial Action Cable registration before retry" do
    visit dev_login_path(as: "alice")

    with_status_catch_up_observer do |catch_ups|
      result = evaluate_script(<<~JS)
        (async () => {
          const { cable } = await import("@hotwired/turbo-rails")
          const sourceClass = customElements.get("hive-status-stream-source")
          const liveSource = document.querySelector("#status-stream-source")
          const originalConsumer = await cable.getConsumer()
          const originalRetryDelay = sourceClass.retryDelay
          const failedConsumer = await cable.createConsumer()
          const owner = document.createElement("div")
          owner.dataset.statusVersion = `retry-${crypto.randomUUID()}`
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", liveSource.getAttribute("channel"))
          source.setAttribute("signed-stream-name", liveSource.getAttribute("signed-stream-name"))
          source.catchUpRefresh = { token: owner.dataset.statusVersion, location: source.statusLocation }
          owner.appendChild(source)
          let disconnects = 0
          let recoveredConsumer
          const disconnect = failedConsumer.disconnect.bind(failedConsumer)
          failedConsumer.disconnect = () => {
            disconnects += 1
            return disconnect()
          }
          failedConsumer.connection.open = () => {
            throw new Error("WebSocket construction failed after registration")
          }

          const cleanup = () => {
            owner.remove()
            recoveredConsumer?.disconnect()
            sourceClass.retryDelay = originalRetryDelay
            cable.setConsumer(originalConsumer)
            delete window.hiveStatusRetryCleanup
          }

          try {
            sourceClass.retryDelay = 0
            cable.setConsumer(failedConsumer)
            const connected = new Promise((resolve, reject) => {
              const deadline = setTimeout(() => reject(new Error("status retry did not connect")), 5_000)
              const observer = new MutationObserver(() => {
                if (!source.hasAttribute("connected")) return

                clearTimeout(deadline)
                observer.disconnect()
                resolve(true)
              })
              observer.observe(source, { attributes: true, attributeFilter: ["connected"] })
            })
            document.body.appendChild(owner)
            await connected
            recoveredConsumer = await cable.getConsumer()
            window.hiveStatusRetryCleanup = cleanup

            return {
              connected: source.hasAttribute("connected"),
              disconnects,
              orphaned: failedConsumer.subscriptions.subscriptions.length,
              consumerReplaced: recoveredConsumer !== failedConsumer,
              pageToken: owner.dataset.statusVersion
            }
          } catch (error) {
            cleanup()
            throw error
          }
        })()
      JS

      assert_equal 0, result.fetch("orphaned")
      assert_equal 1, result.fetch("disconnects")
      assert result.fetch("consumerReplaced")
      assert result.fetch("connected")
      catch_up = wait_for_status_catch_up(catch_ups, result.fetch("pageToken"))
      assert_equal result.fetch("pageToken"), catch_up.fetch("status_version")
    end
  ensure
    cleanup_status_retry_fixture
  end

  test "disconnect cancels a rejected consumer retry before it creates a subscription" do
    visit dev_login_path(as: "alice")

    result = evaluate_script(<<~JS)
      (async () => {
        const { cable } = await import("@hotwired/turbo-rails")
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalConsumer = await cable.getConsumer()
        const originalRetryDelay = sourceClass.retryDelay
        let created = 0
        const owner = document.createElement("div")
        owner.dataset.statusVersion = "cancelled-token"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-token")
        owner.appendChild(source)
        let subscribeCalls = 0
        const subscribe = source.subscribe.bind(source)
        source.subscribe = (...args) => {
          subscribeCalls += 1
          return subscribe(...args)
        }

        try {
          sourceClass.retryDelay = 100
          cable.setConsumer(Promise.reject(new Error("consumer setup failed")))
          document.body.appendChild(owner)

          const deadline = performance.now() + 1_000
          while (!source.statusConnection?.retryTimer && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const rejectedConnection = source.statusConnection
          if (!rejectedConnection?.retryTimer) throw new Error("retry was not scheduled")
          const subscribeCallsAfterSchedule = subscribeCalls

          owner.remove()
          await Promise.resolve()
          cable.setConsumer({
            subscriptions: {
              create() {
                created += 1
                return { unsubscribe() {}, perform() { return true } }
              }
            }
          })
          await new Promise((resolve) => setTimeout(resolve, 150))

          return {
            created,
            retryCleared: rejectedConnection.retryTimer === null,
            subscribeCalls,
            subscribeCallsAfterSchedule
          }
        } finally {
          owner.remove()
          sourceClass.retryDelay = originalRetryDelay
          cable.setConsumer(originalConsumer)
        }
      })()
    JS

    assert_equal({ "created" => 0, "retryCleared" => true,
                   "subscribeCalls" => 1, "subscribeCallsAfterSchedule" => 1 }, result,
                 "a detached source must not restart server work from a rejected setup timer")
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

  def wait_for_status_catch_up(catch_ups, token)
    Timeout.timeout(10) do
      loop do
        catch_up = catch_ups.pop
        return catch_up if catch_up.fetch("status_version") == token
      end
    end
  end

  def cleanup_status_retry_fixture
    return unless page&.current_url

    execute_script("window.hiveStatusRetryCleanup?.()")
  rescue StandardError
    # The browser can already be gone while unwinding a failed system test.
  end

  def with_replaced_instance_method(receiver, name, replacement)
    original = receiver.instance_method(name)
    visibility = if receiver.private_method_defined?(name)
      :private
    elsif receiver.protected_method_defined?(name)
      :protected
    else
      :public
    end
    receiver.define_method(name, replacement)
    receiver.send(visibility, name)
    yield
  ensure
    receiver.define_method(name, original)
    receiver.send(visibility, name)
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
