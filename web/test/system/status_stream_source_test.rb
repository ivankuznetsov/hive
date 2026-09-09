require "application_system_test_case"

class StatusStreamSourceTest < ApplicationSystemTestCase
  teardown { StatusBroadcaster.stop! }

  test "DOM teardown waits for Cable confirmation before server unsubscribe" do
    sign_in!
    visit repos_path
    assert_no_selector "#status-stream-source", visible: :all
    wait_for_status_subscribers(0)

    entered_subscription = Queue.new
    release_subscription = Queue.new
    connected = Queue.new
    disconnected = Queue.new
    released = false
    original_connected = StatusBroadcaster.method(:subscriber_connected!)
    original_disconnected = StatusBroadcaster.method(:subscriber_disconnected!)
    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])
    original_verifier = StatusChannel.instance_method(:verified_stream_name_from_params)
    blocked_verifier = proc do
      entered_subscription << true
      release_subscription.pop
      original_verifier.bind_call(self)
    end

    record_connected = lambda do
      original_connected.call
      connected << StatusBroadcaster.instance_variable_get(:@subscriber_count).to_i
    end
    record_disconnected = lambda do
      original_disconnected.call
      disconnected << StatusBroadcaster.instance_variable_get(:@subscriber_count).to_i
    end

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, record_connected) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, record_disconnected) do
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
            window.pendingStatusLifecycleOwner = source.statusOwner
          JS
          Timeout.timeout(10) { entered_subscription.pop }

          execute_script("document.querySelector('#pending-status-owner').remove()")
          release_subscription << true
          released = true

          assert_equal 1, Timeout.timeout(10) { connected.pop }
          assert_equal 0, Timeout.timeout(10) { disconnected.pop }
        end
      end
    end

    wait_for_status_subscribers(0)
    lifecycle = evaluate_script(<<~JS)
      (() => {
        const owner = window.pendingStatusLifecycleOwner
        return {
          state: owner.state,
          currentAttempt: Boolean(owner.currentAttempt),
          pendingRelease: Boolean(owner.pendingReleaseDisposition),
          pendingTimer: Boolean(owner.pendingReleaseTimer),
          retryTimer: Boolean(owner.retryTimer)
        }
      })()
    JS
    assert_equal({
      "state" => "disconnected",
      "currentAttempt" => false,
      "pendingRelease" => false,
      "pendingTimer" => false,
      "retryTimer" => false
    }, lifecycle)
    assert connected.empty?
    assert disconnected.empty?
  ensure
    release_subscription << true if release_subscription && !released
    if page&.current_url
      execute_script(<<~JS)
        document.querySelector("#pending-status-owner")?.remove()
        delete window.pendingStatusLifecycleOwner
      JS
    end
  end

  test "DOM teardown during reconnect waits for the current confirmation" do
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
    wait_for_status_subscribers(1)

    retained = evaluate_script(<<~JS)
      (() => {
        const source = document.querySelector("#status-stream-source")
        const host = source.closest("[data-status-version]")
        const lifecycle = source.statusOwner
        const attempt = lifecycle.currentAttempt
        const subscription = attempt.subscription
        subscription.disconnected({ willAttemptReconnect: true })
        window.testReconnectingStatusLifecycle = lifecycle
        window.testReconnectingStatusAttempt = attempt
        window.testReconnectingStatusSubscription = subscription
        host.remove()
        return {
          state: lifecycle.state,
          pending: lifecycle.pendingReleaseDisposition?.attempt === attempt,
          retained: attempt.subscription === subscription && !attempt.released,
          timerOwned: Boolean(lifecycle.pendingReleaseTimer),
          attemptRetired: attempt.retired
        }
      })()
    JS

    assert_equal({
      "state" => "disconnected",
      "pending" => true,
      "retained" => true,
      "timerOwned" => true,
      "attemptRetired" => false
    }, retained)
    execute_script("window.testReconnectingStatusSubscription.connected({ reconnected: true })")
    wait_for_status_subscribers(0)
    released = evaluate_script(<<~JS)
      (() => {
        const owner = window.testReconnectingStatusLifecycle
        const attempt = window.testReconnectingStatusAttempt
        return {
          state: owner.state,
          pending: Boolean(owner.pendingReleaseDisposition),
          timerOwned: Boolean(owner.pendingReleaseTimer),
          attemptRetired: attempt.retired,
          subscriptionReleased: attempt.released && attempt.subscription === null,
          consumerReleased: attempt.consumer === null
        }
      })()
    JS
    assert_equal({
      "state" => "disconnected",
      "pending" => false,
      "timerOwned" => false,
      "attemptRetired" => true,
      "subscriptionReleased" => true,
      "consumerReleased" => true
    }, released)
  ensure
    if page&.current_url
      execute_script(<<~JS)
        window.testReconnectingStatusSubscription?.unsubscribe?.()
        delete window.testReconnectingStatusLifecycle
        delete window.testReconnectingStatusAttempt
        delete window.testReconnectingStatusSubscription
      JS
    end
  end

  test "a detached source has bounded cleanup when confirmation never arrives" do
    sign_in!
    visit repos_path
    wait_for_status_subscribers(0)

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalDelay = sourceClass.pendingReleaseDelay
        const events = []
        let disconnects = 0
        let socketCloses = 0
        let unsubscribes = 0
        let callbacks
        const socket = {
          readyState: WebSocket.CONNECTING,
          close() {
            events.push("socket_close")
            socketCloses += 1
            this.readyState = WebSocket.CLOSING
          }
        }
        const fakeConsumer = {
          connection: {
            webSocket: socket,
            close() { events.push("connection_close") }
          },
          subscriptions: {
            create(_channel, mixin) {
              callbacks = mixin
              const subscription = {
                perform() { return true },
                unsubscribe() {
                  events.push("unsubscribe")
                  unsubscribes += 1
                }
              }
              return subscription
            }
          },
          disconnect() {
            events.push("disconnect")
            disconnects += 1
          }
        }
        const owner = document.createElement("div")
        owner.dataset.statusVersion = "pending-token"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-token")
        owner.appendChild(source)

        try {
          sourceClass.pendingReleaseDelay = 0
          source.createConsumer = async () => fakeConsumer
          document.body.appendChild(owner)
          const setupDeadline = performance.now() + 1_000
          while (!source.statusOwner?.currentAttempt?.subscription && performance.now() < setupDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const lifecycle = source.statusOwner
          const attempt = lifecycle?.currentAttempt
          if (!attempt?.subscription) throw new Error("pending subscription was not created")

          owner.remove()
          const cleanupDeadline = performance.now() + 1_000
          while (!attempt.released && performance.now() < cleanupDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const beforeLateCallbacks = { disconnects, socketCloses, unsubscribes }
          callbacks.connected({ reconnected: false })
          callbacks.rejected()
          callbacks.disconnected({ willAttemptReconnect: false })

          return {
            disconnects,
            socketCloses,
            unsubscribes,
            events,
            state: lifecycle.state,
            attemptRetired: attempt.retired,
            activeTransport: socket.readyState === WebSocket.OPEN ||
              socket.readyState === WebSocket.CONNECTING,
            pendingTimer: Boolean(lifecycle.pendingReleaseTimer),
            retryTimer: Boolean(lifecycle.retryTimer),
            lateCallbacksInert: lifecycle.currentAttempt === null &&
              lifecycle.pendingReleaseDisposition === null &&
              disconnects === beforeLateCallbacks.disconnects &&
              socketCloses === beforeLateCallbacks.socketCloses &&
              unsubscribes === beforeLateCallbacks.unsubscribes
          }
        } finally {
          owner.remove()
          sourceClass.pendingReleaseDelay = originalDelay
        }
      })()
    JS

    assert_equal({
      "disconnects" => 1,
      "socketCloses" => 1,
      "unsubscribes" => 1,
      "events" => [ "disconnect", "connection_close", "socket_close", "unsubscribe" ],
      "state" => "disconnected",
      "attemptRetired" => true,
      "activeTransport" => false,
      "pendingTimer" => false,
      "retryTimer" => false,
      "lateCallbacksInert" => true
    }, result)
  end

  test "a real unconfirmed status lease is released by bounded transport cleanup" do
    sign_in!
    visit repos_path
    wait_for_status_subscribers(0)

    signed_name = Turbo::StreamsChannel.signed_stream_name([ StatusBroadcaster::CHANNEL ])
    never_confirm = proc do |*_args, **_kwargs, &_block|
      defer_subscription_confirmation!
    end

    with_replaced_instance_method(StatusChannel, :stream_from, never_confirm) do
      original_delay = evaluate_script(<<~JS, signed_name)
        (() => {
          const sourceClass = customElements.get("hive-status-stream-source")
          const originalDelay = sourceClass.pendingReleaseDelay
          sourceClass.pendingReleaseDelay = 50
          const host = document.createElement("div")
          host.id = "real-pending-status-owner"
          host.dataset.statusVersion = "real-pending-token"
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", "StatusChannel")
          source.setAttribute("signed-stream-name", arguments[0])
          host.appendChild(source)
          document.body.appendChild(host)
          window.realPendingStatusFixture = { host, source }
          return originalDelay
        })()
      JS

      wait_for_status_subscribers(1)
      execute_script(<<~JS)
        const { host, source } = window.realPendingStatusFixture
        window.realPendingStatusLifecycle = source.statusOwner
        window.realPendingStatusAttempt = source.statusOwner.currentAttempt
        host.remove()
      JS
      wait_for_status_subscribers(0)

      result = evaluate_script(<<~JS)
        (() => {
          const lifecycle = window.realPendingStatusLifecycle
          const attempt = window.realPendingStatusAttempt
          return {
            state: lifecycle.state,
            retired: attempt.retired,
            released: attempt.released,
            detached: attempt.subscription === null && attempt.consumer === null &&
              attempt.connection === null && attempt.socket === null,
            pendingTimer: Boolean(lifecycle.pendingReleaseTimer),
            pendingDisposition: Boolean(lifecycle.pendingReleaseDisposition),
            retryTimer: Boolean(lifecycle.retryTimer)
          }
        })()
      JS

      assert_equal({
        "state" => "disconnected",
        "retired" => true,
        "released" => true,
        "detached" => true,
        "pendingTimer" => false,
        "pendingDisposition" => false,
        "retryTimer" => false
      }, result)
    ensure
      if page&.current_url
        execute_script(<<~JS, original_delay)
          window.realPendingStatusFixture?.host?.remove()
          if (arguments[0] !== null) {
            customElements.get("hive-status-stream-source").pendingReleaseDelay = arguments[0]
          }
          delete window.realPendingStatusFixture
          delete window.realPendingStatusLifecycle
          delete window.realPendingStatusAttempt
        JS
      end
    end
  end

  test "a pending consumer setup is fenced across immediate detach and reattach" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const pendingConsumers = []
        let factoryCalls = 0
        let creates = 0
        let unsubscribes = 0
        let firstDisconnects = 0
        let secondDisconnects = 0
        const host = document.createElement("div")
        host.dataset.statusVersion = "pending-reattach"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-pending-reattach")
        source.createConsumer = () => {
          factoryCalls += 1
          return new Promise((resolve) => pendingConsumers.push(resolve))
        }
        host.appendChild(source)

        try {
          document.body.appendChild(host)
          const firstOwner = source.statusOwner
          const firstAttempt = firstOwner.currentAttempt
          host.remove()
          document.body.appendChild(host)
          const secondOwner = source.statusOwner

          pendingConsumers[0]({
            disconnect() { firstDisconnects += 1 },
            subscriptions: { create() { throw new Error("stale consumer registered") } }
          })
          pendingConsumers[1]({
            disconnect() { secondDisconnects += 1 },
            subscriptions: {
              create(_channel, callbacks) {
                creates += 1
                const subscription = {
                  perform() { return true },
                  unsubscribe() { unsubscribes += 1 }
                }
                queueMicrotask(() => callbacks.connected({ reconnected: false }))
                return subscription
              }
            }
          })

          const deadline = performance.now() + 1_000
          while (!source.hasAttribute("connected") && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const afterReconnect = {
            connected: source.hasAttribute("connected"),
            factoryCalls,
            creates,
            unsubscribes,
            firstDisconnects,
            ownersDiffer: firstOwner !== secondOwner,
            firstRetired: firstAttempt.retired
          }
          host.remove()
          return {
            afterReconnect,
            afterDisconnect: { unsubscribes, firstDisconnects, secondDisconnects }
          }
        } finally {
          host.remove()
        }
      })()
    JS

    assert_equal({
      "connected" => true,
      "factoryCalls" => 2,
      "creates" => 1,
      "unsubscribes" => 0,
      "firstDisconnects" => 1,
      "ownersDiffer" => true,
      "firstRetired" => true
    }, result.fetch("afterReconnect"))
    assert_equal({
      "unsubscribes" => 1,
      "firstDisconnects" => 1,
      "secondDisconnects" => 1
    }, result.fetch("afterDisconnect"))
  end

  test "each setup attempt owns a dedicated consumer without changing Turbo's shared consumer" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const { cable } = await import("@hotwired/turbo-rails")
        const sharedConsumer = await cable.getConsumer()
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalCreate = sourceClass.prototype.createConsumer
        const consumers = []
        const makeConsumer = () => {
          const consumer = {
            disconnected: 0,
            disconnect() { this.disconnected += 1 },
            subscriptions: {
              create(_channel, callbacks) {
                const subscription = {
                  perform() { return true },
                  unsubscribe() {}
                }
                queueMicrotask(() => callbacks.connected({ reconnected: false }))
                return subscription
              }
            }
          }
          consumers.push(consumer)
          return consumer
        }
        const appendSource = () => {
          const owner = document.createElement("div")
          owner.dataset.statusVersion = crypto.randomUUID()
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", "StatusChannel")
          source.setAttribute("signed-stream-name", "test-token")
          owner.appendChild(source)
          document.body.appendChild(owner)
          return { owner, source }
        }

        sourceClass.prototype.createConsumer = async () => makeConsumer()
        const first = appendSource()
        const second = appendSource()
        try {
          const deadline = performance.now() + 1_000
          while ((!first.source.hasAttribute("connected") || !second.source.hasAttribute("connected"))
            && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }

          return {
            connected: first.source.hasAttribute("connected") && second.source.hasAttribute("connected"),
            consumers: consumers.length,
            isolated: first.source.statusOwner?.currentAttempt?.consumer !==
              second.source.statusOwner?.currentAttempt?.consumer,
            sharedUntouched: (await cable.getConsumer()) === sharedConsumer
          }
        } finally {
          first.owner.remove()
          second.owner.remove()
          sourceClass.prototype.createConsumer = originalCreate
        }
      })()
    JS

    assert_equal({
      "connected" => true,
      "consumers" => 2,
      "isolated" => true,
      "sharedUntouched" => true
    }, result)
  end

  test "direct teardown is fallback-only, failure-complete, and preserves the first thrown value" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const runScenario = async (options) => {
          const sentinels = {
            unsubscribe: { seam: `${options.name}-unsubscribe` },
            consumer: { seam: `${options.name}-consumer` },
            connection: { seam: `${options.name}-connection` },
            socket: { seam: `${options.name}-socket` },
            readyState: { seam: `${options.name}-ready-state` },
            retryTimer: { seam: `${options.name}-retry-timer` }
          }
          const counters = {
            unsubscribe: 0,
            consumerDisconnect: 0,
            primaryConnectionClose: 0,
            fallbackConnectionClose: 0,
            primarySocketClose: 0,
            fallbackConnectionSocketClose: 0,
            rawSocketClose: 0,
            readyStateReads: 0,
            monitorStop: 0,
            retryCancel: 0,
            open: 0,
            reopen: 0
          }
          let socketState = options.socketState
          let readyStateFailures = options.readyStateFailures || 0
          let phase = null
          const monitor = {
            running: true,
            isRunning() { return this.running },
            stop() {
              counters.monitorStop += 1
              this.running = false
            }
          }
          const socket = {
            get readyState() {
              counters.readyStateReads += 1
              if (readyStateFailures > 0) {
                readyStateFailures -= 1
                throw sentinels.readyState
              }
              return socketState
            },
            close() {
              if (phase === "consumer") counters.primarySocketClose += 1
              else if (phase === "connection-fallback") counters.fallbackConnectionSocketClose += 1
              else counters.rawSocketClose += 1
              if (options.failSocket) throw sentinels.socket
              socketState = WebSocket.CLOSING
            }
          }
          const connection = {
            monitor,
            webSocket: socket,
            open() { counters.open += 1; return true },
            reopen() { counters.reopen += 1; return this.open() },
            close({ allowReconnect } = {}) {
              if (phase === "consumer") counters.primaryConnectionClose += 1
              else counters.fallbackConnectionClose += 1
              if (allowReconnect === false && options.failConnection) throw sentinels.connection
              if (allowReconnect === false) monitor.stop()
              if (socketState === WebSocket.OPEN) socket.close()
            }
          }
          let callbacks
          const subscription = {
            perform() { return true },
            unsubscribe() {
              counters.unsubscribe += 1
              if (options.failUnsubscribe) throw sentinels.unsubscribe
            }
          }
          const consumer = {
            connection,
            disconnect() {
              counters.consumerDisconnect += 1
              if (options.failConsumer) throw sentinels.consumer
              if (options.consumerLeavesOpen) {
                monitor.stop()
                return
              }
              phase = "consumer"
              try {
                connection.close({ allowReconnect: false })
              } finally {
                phase = null
              }
            },
            subscriptions: {
              create(_channel, mixin) {
                callbacks = mixin
                queueMicrotask(() => mixin.connected({ reconnected: false }))
                return subscription
              }
            }
          }
          const host = document.createElement("div")
          host.dataset.statusVersion = options.name
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", "StatusChannel")
          source.setAttribute("signed-stream-name", `test-${options.name}`)
          source.createConsumer = async () => consumer
          host.appendChild(source)
          document.body.appendChild(host)

          let originalClearTimeout
          let caught
          let caughtValue
          try {
            const deadline = performance.now() + 1_000
            while (!source.hasAttribute("connected") && performance.now() < deadline) {
              await new Promise((resolve) => setTimeout(resolve, 0))
            }
            const owner = source.statusOwner
            const attempt = owner.currentAttempt
            const queuedOpen = connection.open
            const queuedReopen = connection.reopen
            if (options.failRetryTimer) {
              owner.retryTimer = 123_456
              originalClearTimeout = window.clearTimeout
              window.clearTimeout = () => {
                counters.retryCancel += 1
                throw sentinels.retryTimer
              }
            }

            try {
              owner.disconnect()
            } catch (error) {
              caught = true
              caughtValue = error
            } finally {
              if (originalClearTimeout) window.clearTimeout = originalClearTimeout
            }
            owner.disconnect()
            queuedOpen()
            queuedReopen()
            callbacks.connected({ reconnected: true })
            callbacks.rejected()
            callbacks.disconnected({ willAttemptReconnect: false })

            return {
              caught: Boolean(caught),
              caughtSeam: Object.entries(sentinels).find(([, value]) => value === caughtValue)?.[0] || null,
              exactIdentity: options.expectedError ? caughtValue === sentinels[options.expectedError] : !caught,
              counters,
              state: owner.state,
              currentAttempt: Boolean(owner.currentAttempt),
              retryTimerCleared: owner.retryTimer === null,
              attemptRetired: attempt.retired,
              attemptDetached: attempt.subscription === null && attempt.consumer === null &&
                attempt.connection === null && attempt.socket === null,
              monitorRunning: monitor.running,
              socketState
            }
          } finally {
            if (originalClearTimeout) window.clearTimeout = originalClearTimeout
            host.remove()
          }
        }

        return {
          normalOpen: await runScenario({
            name: "normal-open",
            socketState: WebSocket.OPEN
          }),
          connecting: await runScenario({
            name: "connecting",
            socketState: WebSocket.CONNECTING
          }),
          cascade: await runScenario({
            name: "cascade",
            socketState: WebSocket.OPEN,
            failUnsubscribe: true,
            failConsumer: true,
            failConnection: true,
            failSocket: true,
            expectedError: "unsubscribe"
          }),
          readyState: await runScenario({
            name: "ready-state",
            socketState: WebSocket.OPEN,
            consumerLeavesOpen: true,
            readyStateFailures: 1,
            expectedError: "readyState"
          }),
          connectionFailure: await runScenario({
            name: "connection-failure",
            socketState: WebSocket.OPEN,
            consumerLeavesOpen: true,
            failConnection: true,
            expectedError: "connection"
          }),
          retryTimer: await runScenario({
            name: "retry-timer",
            socketState: WebSocket.OPEN,
            failRetryTimer: true,
            expectedError: "retryTimer"
          }),
          connectingSocketFailure: await runScenario({
            name: "connecting-socket-failure",
            socketState: WebSocket.CONNECTING,
            failSocket: true,
            expectedError: "socket"
          })
        }
      })()
    JS

    normal = result.fetch("normalOpen")
    refute normal.fetch("caught")
    assert normal.fetch("exactIdentity")
    assert_equal 1, normal.dig("counters", "unsubscribe")
    assert_equal 1, normal.dig("counters", "consumerDisconnect")
    assert_equal 1, normal.dig("counters", "primaryConnectionClose")
    assert_equal 0, normal.dig("counters", "fallbackConnectionClose")
    assert_equal 1, normal.dig("counters", "primarySocketClose")
    assert_equal 0, normal.dig("counters", "rawSocketClose")

    connecting = result.fetch("connecting")
    assert_equal 1, connecting.dig("counters", "unsubscribe")
    assert_equal 1, connecting.dig("counters", "consumerDisconnect")
    assert_equal 1, connecting.dig("counters", "fallbackConnectionClose")
    assert_equal 1, connecting.dig("counters", "rawSocketClose")

    cascade = result.fetch("cascade")
    assert cascade.fetch("exactIdentity")
    assert_equal "unsubscribe", cascade.fetch("caughtSeam")
    assert_equal 1, cascade.dig("counters", "unsubscribe")
    assert_equal 1, cascade.dig("counters", "consumerDisconnect")
    assert_equal 1, cascade.dig("counters", "fallbackConnectionClose")
    assert_equal 1, cascade.dig("counters", "rawSocketClose")
    assert_equal 1, cascade.dig("counters", "monitorStop")

    ready_state = result.fetch("readyState")
    assert ready_state.fetch("exactIdentity")
    assert_equal 2, ready_state.dig("counters", "readyStateReads")
    assert_equal 0, ready_state.dig("counters", "fallbackConnectionClose")
    assert_equal 1, ready_state.dig("counters", "rawSocketClose")

    connection_failure = result.fetch("connectionFailure")
    assert connection_failure.fetch("exactIdentity")
    assert_equal 1, connection_failure.dig("counters", "fallbackConnectionClose")
    assert_equal 1, connection_failure.dig("counters", "rawSocketClose")

    retry_timer = result.fetch("retryTimer")
    assert retry_timer.fetch("exactIdentity")
    assert_equal 1, retry_timer.dig("counters", "retryCancel")
    assert_equal 1, retry_timer.dig("counters", "unsubscribe")
    assert_equal 1, retry_timer.dig("counters", "consumerDisconnect")

    connecting_socket_failure = result.fetch("connectingSocketFailure")
    assert connecting_socket_failure.fetch("exactIdentity")
    assert_equal 1, connecting_socket_failure.dig("counters", "rawSocketClose")

    result.each_value do |scenario|
      assert_equal "disconnected", scenario.fetch("state")
      refute scenario.fetch("currentAttempt")
      assert scenario.fetch("retryTimerCleared")
      assert scenario.fetch("attemptRetired")
      assert scenario.fetch("attemptDetached")
      refute scenario.fetch("monitorRunning")
      assert_equal 0, scenario.dig("counters", "open")
      assert_equal 0, scenario.dig("counters", "reopen")
    end
  end

  test "a socket created by a throwing open remains reachable for cleanup" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalDelay = sourceClass.retryDelay
        const originalWarn = console.warn
        const warnings = []
        let socketCloses = 0
        let disconnects = 0
        const socket = {
          readyState: WebSocket.CONNECTING,
          close() {
            socketCloses += 1
            this.readyState = WebSocket.CLOSING
          }
        }
        const connection = {
          webSocket: null,
          open() {
            this.webSocket = socket
            throw new Error("open failed after socket allocation")
          },
          close() {}
        }
        const consumer = {
          connection,
          disconnect() { disconnects += 1 },
          subscriptions: {
            create() {
              connection.open()
              return { perform() { return true }, unsubscribe() {} }
            }
          }
        }
        const host = document.createElement("div")
        host.dataset.statusVersion = "throwing-open"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-throwing-open")
        source.createConsumer = async () => consumer
        host.appendChild(source)

        try {
          sourceClass.retryDelay = 10_000
          console.warn = (...args) => warnings.push(args)
          document.body.appendChild(host)
          const lifecycle = source.statusOwner
          const attempt = lifecycle.currentAttempt
          const deadline = performance.now() + 1_000
          while (lifecycle.state !== "retry_wait" && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          return {
            state: lifecycle.state,
            retired: attempt.retired,
            detached: attempt.socket === null && attempt.connection === null && attempt.consumer === null,
            disconnects,
            socketCloses,
            socketState: socket.readyState,
            warnings: warnings.length
          }
        } finally {
          host.remove()
          sourceClass.retryDelay = originalDelay
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal({
      "state" => "retry_wait",
      "retired" => true,
      "detached" => true,
      "disconnects" => 1,
      "socketCloses" => 1,
      "socketState" => 2,
      "warnings" => 1
    }, result)
  end

  test "real DOM disconnect warns once after cleanup and recovers with a fresh owner" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const originalWarn = console.warn
        const warnings = []
        const pageErrors = []
        const unhandled = []
        const sentinel = { seam: "dom-unsubscribe" }
        let factoryCalls = 0
        let failedDisconnects = 0
        let recoveredSubscriptions = 0
        let activeSubscriptions = 0
        const onError = (event) => { pageErrors.push(event.error || event.message); event.preventDefault() }
        const onUnhandled = (event) => { unhandled.push(event.reason); event.preventDefault() }
        const host = document.createElement("div")
        host.dataset.statusVersion = "dom-disconnect"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-dom-disconnect")
        host.appendChild(source)
        source.createConsumer = async () => {
          factoryCalls += 1
          const failed = factoryCalls === 1
          return {
            disconnect() {
              if (failed) failedDisconnects += 1
              activeSubscriptions = Math.max(0, activeSubscriptions - 1)
            },
            subscriptions: {
              create(_channel, callbacks) {
                activeSubscriptions += 1
                if (!failed) recoveredSubscriptions += 1
                const subscription = {
                  perform() { return true },
                  unsubscribe() {
                    if (failed) throw sentinel
                    activeSubscriptions = Math.max(0, activeSubscriptions - 1)
                  }
                }
                queueMicrotask(() => callbacks.connected({ reconnected: false }))
                return subscription
              }
            }
          }
        }

        try {
          console.warn = (...args) => warnings.push(args)
          addEventListener("error", onError)
          addEventListener("unhandledrejection", onUnhandled)
          document.body.appendChild(host)
          const firstDeadline = performance.now() + 1_000
          while (!source.hasAttribute("connected") && performance.now() < firstDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const failedOwner = source.statusOwner
          const failedAttempt = failedOwner.currentAttempt
          host.remove()
          await new Promise((resolve) => setTimeout(resolve, 0))
          const afterDisconnect = {
            ownerCleared: source.statusOwner === null,
            connectedAttribute: source.hasAttribute("connected"),
            state: failedOwner.state,
            attemptRetired: failedAttempt.retired,
            attemptDetached: failedAttempt.subscription === null && failedAttempt.consumer === null,
            warningCount: warnings.length,
            exactWarning: warnings[0]?.includes(sentinel) || false,
            pageErrors: pageErrors.length,
            unhandled: unhandled.length,
            failedDisconnects
          }

          document.body.appendChild(host)
          const recoveryDeadline = performance.now() + 1_000
          while (!source.hasAttribute("connected") && performance.now() < recoveryDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          return {
            afterDisconnect,
            recovered: source.hasAttribute("connected"),
            freshOwner: source.statusOwner !== failedOwner,
            freshAttempt: source.statusOwner?.currentAttempt !== failedAttempt,
            factoryCalls,
            recoveredSubscriptions,
            activeSubscriptions,
            warningCount: warnings.length,
            pageErrors: pageErrors.length,
            unhandled: unhandled.length
          }
        } finally {
          host.remove()
          removeEventListener("error", onError)
          removeEventListener("unhandledrejection", onUnhandled)
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal({
      "ownerCleared" => true,
      "connectedAttribute" => false,
      "state" => "disconnected",
      "attemptRetired" => true,
      "attemptDetached" => true,
      "warningCount" => 1,
      "exactWarning" => true,
      "pageErrors" => 0,
      "unhandled" => 0,
      "failedDisconnects" => 1
    }, result.fetch("afterDisconnect"))
    assert result.fetch("recovered")
    assert result.fetch("freshOwner")
    assert result.fetch("freshAttempt")
    assert_equal 2, result.fetch("factoryCalls")
    assert_equal 1, result.fetch("recoveredSubscriptions")
    assert_equal 1, result.fetch("activeSubscriptions")
    assert_equal 1, result.fetch("warningCount")
    assert_equal 0, result.fetch("pageErrors")
    assert_equal 0, result.fetch("unhandled")
  end

  test "a retry restores Turbo stream registration after owner setup fails" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalDelay = sourceClass.retryDelay
        const originalWarn = console.warn
        const pageErrors = []
        const unhandled = []
        const onError = (event) => { pageErrors.push(event.error || event.message); event.preventDefault() }
        const onUnhandled = (event) => { unhandled.push(event.reason); event.preventDefault() }
        let connectCalls = 0
        let disconnectCalls = 0
        let factoryCalls = 0
        let failConnect = true
        const host = document.createElement("div")
        host.dataset.statusVersion = "turbo-registration-retry"
        const target = document.createElement("div")
        target.id = "turbo-registration-retry-target"
        target.textContent = "stale"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-turbo-registration-retry")
        const originalConnect = source.connectTurboStreamSource.bind(source)
        const originalDisconnect = source.disconnectTurboStreamSource.bind(source)
        source.connectTurboStreamSource = () => {
          connectCalls += 1
          if (failConnect) throw new Error("Turbo registration failed")
          return originalConnect()
        }
        source.disconnectTurboStreamSource = () => {
          disconnectCalls += 1
          return originalDisconnect()
        }
        source.createConsumer = async () => {
          factoryCalls += 1
          return {
            disconnect() {},
            subscriptions: {
              create(_channel, callbacks) {
                const subscription = { perform() { return true }, unsubscribe() {} }
                queueMicrotask(() => callbacks.connected({ reconnected: false }))
                return subscription
              }
            }
          }
        }
        host.append(source, target)

        try {
          sourceClass.retryDelay = 50
          console.warn = () => {}
          addEventListener("error", onError)
          addEventListener("unhandledrejection", onUnhandled)
          document.body.appendChild(host)
          const lifecycle = source.statusOwner
          const retryDeadline = performance.now() + 1_000
          while (connectCalls < 3 && performance.now() < retryDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const persistentRetry = {
            state: lifecycle.state,
            timerOwned: Boolean(lifecycle.retryTimer),
            currentAttempt: Boolean(lifecycle.currentAttempt),
            connectCalls
          }
          failConnect = false
          const deadline = performance.now() + 1_000
          while (!source.hasAttribute("connected") && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          source.dispatchMessageEvent(
            '<turbo-stream action="update" target="turbo-registration-retry-target"><template>fresh</template></turbo-stream>'
          )
          const renderDeadline = performance.now() + 1_000
          while (target.textContent !== "fresh" && performance.now() < renderDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const connected = source.hasAttribute("connected")
          host.remove()
          return {
            persistentRetry,
            connected,
            connectCalls,
            disconnectCalls,
            factoryCalls,
            rendered: target.textContent,
            pageErrors: pageErrors.length,
            unhandled: unhandled.length
          }
        } finally {
          host.remove()
          removeEventListener("error", onError)
          removeEventListener("unhandledrejection", onUnhandled)
          sourceClass.retryDelay = originalDelay
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal "retry_wait", result.dig("persistentRetry", "state")
    assert result.dig("persistentRetry", "timerOwned")
    refute result.dig("persistentRetry", "currentAttempt")
    assert_operator result.dig("persistentRetry", "connectCalls"), :>=, 3
    assert result.fetch("connected")
    assert_operator result.fetch("connectCalls"), :>=, 4
    assert_equal 1, result.fetch("disconnectCalls")
    assert_equal 1, result.fetch("factoryCalls")
    assert_equal "fresh", result.fetch("rendered")
    assert_equal 0, result.fetch("pageErrors")
    assert_equal 0, result.fetch("unhandled")
  end

  test "attribute supersession installs a failed successor before reporting old teardown" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalDelay = sourceClass.retryDelay
        const originalWarn = console.warn
        const warnings = []
        const pageErrors = []
        const oldSentinel = { seam: "old-unsubscribe" }
        const successorSentinel = { seam: "successor-setup" }
        let factoryCalls = 0
        let oldDisconnects = 0
        const onError = (event) => { pageErrors.push(event.error || event.message); event.preventDefault() }
        const host = document.createElement("div")
        host.dataset.statusVersion = "attribute-supersession"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-old")
        host.appendChild(source)
        source.createConsumer = () => {
          factoryCalls += 1
          if (factoryCalls === 2) throw successorSentinel
          return Promise.resolve({
            disconnect() { oldDisconnects += 1 },
            subscriptions: {
              create(_channel, callbacks) {
                const subscription = {
                  perform() { return true },
                  unsubscribe() {
                    source.connectedCallback()
                    throw oldSentinel
                  }
                }
                queueMicrotask(() => callbacks.connected({ reconnected: false }))
                return subscription
              }
            }
          })
        }

        try {
          sourceClass.retryDelay = 10_000
          console.warn = (...args) => warnings.push(args)
          addEventListener("error", onError)
          document.body.appendChild(host)
          const connectedDeadline = performance.now() + 1_000
          while (!source.hasAttribute("connected") && performance.now() < connectedDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const oldOwner = source.statusOwner
          const oldAttempt = oldOwner.currentAttempt
          source.setAttribute("signed-stream-name", "test-successor")
          await new Promise((resolve) => setTimeout(resolve, 0))
          const successor = source.statusOwner

          return {
            factoryCalls,
            oldDisconnects,
            oldState: oldOwner.state,
            oldRetired: oldAttempt.retired,
            oldDetached: oldAttempt.subscription === null && oldAttempt.consumer === null,
            successorInstalled: Boolean(successor) && successor !== oldOwner,
            successorState: successor?.state,
            successorAttemptRetired: successor?.currentAttempt === null,
            successorRetry: Boolean(successor?.retryTimer),
            warningCount: warnings.length,
            warningOrder: warnings.map((args) => {
              if (args.includes(oldSentinel)) return "old"
              if (args.includes(successorSentinel)) return "successor"
              return "other"
            }),
            pageErrors: pageErrors.length
          }
        } finally {
          host.remove()
          removeEventListener("error", onError)
          console.warn = originalWarn
          sourceClass.retryDelay = originalDelay
        }
      })()
    JS

    assert_equal({
      "factoryCalls" => 2,
      "oldDisconnects" => 1,
      "oldState" => "disconnected",
      "oldRetired" => true,
      "oldDetached" => true,
      "successorInstalled" => true,
      "successorState" => "retry_wait",
      "successorAttemptRetired" => true,
      "successorRetry" => true,
      "warningCount" => 2,
      "warningOrder" => [ "old", "successor" ],
      "pageErrors" => 0
    }, result)
  end

  test "attribute supersession restores warning delivery after successor setup escapes" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (() => {
        const originalWarn = console.warn
        const warnings = []
        const setupFailure = { seam: "successor-setup" }
        const reportingFailure = { seam: "successor-reporting" }
        const laterFailure = { seam: "later-warning" }
        const host = document.createElement("div")
        host.dataset.statusVersion = "warning-queue-restoration"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-old")
        source.createConsumer = () => new Promise(() => {})
        host.appendChild(source)

        let caught
        let oldOwner
        try {
          console.warn = (...args) => warnings.push(args)
          document.body.appendChild(host)
          oldOwner = source.statusOwner
          source.statusOwner = null
          source.connectedCallback = () => {
            source.statusOwner = { state: "retry_wait", disconnect() {} }
            throw setupFailure
          }
          source.reportStatusFailure = () => { throw reportingFailure }
          try {
            source.attributeChangedCallback("signed-stream-name", "test-old", "test-successor")
          } catch (error) {
            caught = error
          }
          delete source.reportStatusFailure
          source.reportStatusFailure("later warning", laterFailure)
          return {
            caughtSetupFailure: caught === reportingFailure,
            queueRestored: source.statusWarningQueue === undefined,
            laterWarningPublished: warnings.some((args) => args.includes(laterFailure))
          }
        } finally {
          host.remove()
          oldOwner?.disconnect()
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal({
      "caughtSetupFailure" => true,
      "queueRestored" => true,
      "laterWarningPublished" => true
    }, result)
  end

  test "a stale unconfirmed registration closes transport before local release" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const events = []
        let factoryCalls = 0
        let staleAttempt
        const socket = {
          readyState: WebSocket.CONNECTING,
          close() {
            events.push("socket_close")
            this.readyState = WebSocket.CLOSING
          }
        }
        const connection = {
          webSocket: socket,
          close() { events.push("connection_close") }
        }
        const host = document.createElement("div")
        host.dataset.statusVersion = "stale-registration-order"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-old")
        source.createConsumer = async () => {
          factoryCalls += 1
          if (factoryCalls > 1) {
            return {
              disconnect() {},
              subscriptions: {
                create(_channel, callbacks) {
                  const subscription = { perform() { return true }, unsubscribe() {} }
                  queueMicrotask(() => callbacks.connected({ reconnected: false }))
                  return subscription
                }
              }
            }
          }

          const consumer = {
            connection,
            disconnect() { events.push("disconnect") },
            subscriptions: {
              create() {
                const owner = source.statusOwner
                staleAttempt = owner.currentAttempt
                source.setAttribute("signed-stream-name", "test-successor")
                events.length = 0
                socket.readyState = WebSocket.CONNECTING
                staleAttempt.consumer = consumer
                staleAttempt.connection = connection
                staleAttempt.socket = socket
                return {
                  perform() { return true },
                  unsubscribe() { events.push("unsubscribe") }
                }
              }
            }
          }
          return consumer
        }
        host.appendChild(source)

        try {
          document.body.appendChild(host)
          const deadline = performance.now() + 1_000
          while ((!staleAttempt?.released || !source.hasAttribute("connected"))
            && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          return {
            events,
            retired: staleAttempt.retired,
            released: staleAttempt.released,
            detached: staleAttempt.subscription === null && staleAttempt.consumer === null &&
              staleAttempt.connection === null && staleAttempt.socket === null
          }
        } finally {
          host.remove()
        }
      })()
    JS

    assert_equal({
      "events" => [ "disconnect", "connection_close", "socket_close", "unsubscribe" ],
      "retired" => true,
      "released" => true,
      "detached" => true
    }, result)
  end

  test "an unconfirmed attempt failure closes transport before local release" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalDelay = sourceClass.retryDelay
        const originalWarn = console.warn
        const events = []
        const host = document.createElement("div")
        host.dataset.statusVersion = "unconfirmed-failure-order"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-unconfirmed-failure-order")
        source.dispatchMessageEvent = () => { throw new Error("message failed before confirmation") }
        source.createConsumer = async () => ({
          disconnect() { events.push("transport") },
          subscriptions: {
            create(_channel, callbacks) {
              const subscription = {
                perform() { return true },
                unsubscribe() { events.push("unsubscribe") }
              }
              queueMicrotask(() => callbacks.received("failing payload"))
              return subscription
            }
          }
        })
        host.appendChild(source)

        try {
          sourceClass.retryDelay = 10_000
          console.warn = () => {}
          document.body.appendChild(host)
          const owner = source.statusOwner
          const deadline = performance.now() + 1_000
          while (owner.state !== "retry_wait" && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          return {
            state: owner.state,
            retryOwned: Boolean(owner.retryTimer),
            events
          }
        } finally {
          host.remove()
          sourceClass.retryDelay = originalDelay
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal({
      "state" => "retry_wait",
      "retryOwned" => true,
      "events" => [ "transport", "unsubscribe" ]
    }, result)
  end

  test "pending release failures warn after timer and custody finalization" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalDelay = sourceClass.pendingReleaseDelay
        const originalWarn = console.warn
        const nativeClearTimeout = window.clearTimeout
        const warnings = []
        const pageErrors = []
        const unhandled = []
        const onError = (event) => { pageErrors.push(event.error || event.message); event.preventDefault() }
        const onUnhandled = (event) => { unhandled.push(event.reason); event.preventDefault() }

        const makeSource = (name, consumer) => {
          const host = document.createElement("div")
          host.dataset.statusVersion = name
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", "StatusChannel")
          source.setAttribute("signed-stream-name", `test-${name}`)
          source.createConsumer = async () => consumer
          host.appendChild(source)
          return { host, source }
        }

        const confirmationCancellation = async () => {
          const sentinel = { seam: "pending-timer-cancel" }
          let callbacks
          let socketState = WebSocket.CONNECTING
          let unsubscribes = 0
          let disconnects = 0
          let timerCancels = 0
          const socket = { get readyState() { return socketState }, close() { socketState = WebSocket.CLOSING } }
          const consumer = {
            connection: { webSocket: socket, close() {} },
            disconnect() { disconnects += 1; socketState = WebSocket.CLOSING },
            subscriptions: {
              create(_channel, mixin) {
                callbacks = mixin
                return {
                  perform() { return true },
                  unsubscribe() { unsubscribes += 1 }
                }
              }
            }
          }
          const { host, source } = makeSource("pending-timer-cancel", consumer)
          const warningStart = warnings.length
          sourceClass.pendingReleaseDelay = 10_000
          document.body.appendChild(host)
          const setupDeadline = performance.now() + 1_000
          while (!callbacks && performance.now() < setupDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const owner = source.statusOwner
          const attempt = owner.currentAttempt
          host.remove()
          const timer = owner.pendingReleaseTimer
          window.clearTimeout = (candidate) => {
            if (candidate === timer) {
              timerCancels += 1
              throw sentinel
            }
            return nativeClearTimeout(candidate)
          }
          let callbackThrew = false
          try {
            callbacks.connected({ reconnected: false })
          } catch (_error) {
            callbackThrew = true
          } finally {
            window.clearTimeout = nativeClearTimeout
            nativeClearTimeout(timer)
          }
          await new Promise((resolve) => setTimeout(resolve, 0))
          return {
            callbackThrew,
            timerCancels,
            unsubscribes,
            disconnects,
            state: owner.state,
            pendingCleared: owner.pendingReleaseDisposition === null,
            timerCleared: owner.pendingReleaseTimer === null,
            retired: attempt.retired,
            detached: attempt.subscription === null && attempt.consumer === null,
            warnings: warnings.length - warningStart,
            exactWarning: warnings.at(-1)?.includes(sentinel) || false
          }
        }

        const timeoutCleanup = async () => {
          const sentinels = {
            consumer: { seam: "timeout-consumer" },
            connection: { seam: "timeout-connection" },
            socket: { seam: "timeout-socket" },
            unsubscribe: { seam: "timeout-unsubscribe" }
          }
          const counters = { consumer: 0, connection: 0, socket: 0, unsubscribe: 0, monitor: 0 }
          let callbacks
          const monitor = {
            running: true,
            isRunning() { return this.running },
            stop() { counters.monitor += 1; this.running = false }
          }
          const socket = {
            readyState: WebSocket.CONNECTING,
            close() { counters.socket += 1; throw sentinels.socket }
          }
          const consumer = {
            connection: {
              webSocket: socket,
              monitor,
              close() { counters.connection += 1; throw sentinels.connection }
            },
            disconnect() { counters.consumer += 1; throw sentinels.consumer },
            subscriptions: {
              create(_channel, mixin) {
                callbacks = mixin
                return {
                  perform() { return true },
                  unsubscribe() { counters.unsubscribe += 1; throw sentinels.unsubscribe }
                }
              }
            }
          }
          const { host, source } = makeSource("pending-timeout-errors", consumer)
          const warningStart = warnings.length
          sourceClass.pendingReleaseDelay = 0
          document.body.appendChild(host)
          const setupDeadline = performance.now() + 1_000
          while (!callbacks && performance.now() < setupDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const owner = source.statusOwner
          const attempt = owner.currentAttempt
          host.remove()
          const cleanupDeadline = performance.now() + 1_000
          while ((!attempt.retired || warnings.length === warningStart)
            && performance.now() < cleanupDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          return {
            counters,
            state: owner.state,
            pendingCleared: owner.pendingReleaseDisposition === null,
            timerCleared: owner.pendingReleaseTimer === null,
            retired: attempt.retired,
            released: attempt.released,
            detached: attempt.subscription === null && attempt.consumer === null &&
              attempt.connection === null && attempt.socket === null,
            monitorRunning: monitor.running,
            warnings: warnings.length - warningStart,
            exactWarning: warnings.at(-1)?.includes(sentinels.consumer) || false
          }
        }

        try {
          console.warn = (...args) => warnings.push(args)
          addEventListener("error", onError)
          addEventListener("unhandledrejection", onUnhandled)
          return {
            confirmationCancellation: await confirmationCancellation(),
            timeoutCleanup: await timeoutCleanup(),
            pageErrors: pageErrors.length,
            unhandled: unhandled.length
          }
        } finally {
          window.clearTimeout = nativeClearTimeout
          sourceClass.pendingReleaseDelay = originalDelay
          removeEventListener("error", onError)
          removeEventListener("unhandledrejection", onUnhandled)
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal({
      "callbackThrew" => false,
      "timerCancels" => 1,
      "unsubscribes" => 1,
      "disconnects" => 1,
      "state" => "disconnected",
      "pendingCleared" => true,
      "timerCleared" => true,
      "retired" => true,
      "detached" => true,
      "warnings" => 1,
      "exactWarning" => true
    }, result.fetch("confirmationCancellation"))
    assert_equal({
      "counters" => {
        "consumer" => 1,
        "connection" => 1,
        "socket" => 1,
        "unsubscribe" => 1,
        "monitor" => 1
      },
      "state" => "disconnected",
      "pendingCleared" => true,
      "timerCleared" => true,
      "retired" => true,
      "released" => true,
      "detached" => true,
      "monitorRunning" => false,
      "warnings" => 1,
      "exactWarning" => true
    }, result.fetch("timeoutCleanup"))
    assert_equal 0, result.fetch("pageErrors")
    assert_equal 0, result.fetch("unhandled")
  end

  test "mounted attempt failures retire before one warning and recover without rejected work" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalDelay = sourceClass.retryDelay
        const originalWarn = console.warn
        const warnings = []
        const pageErrors = []
        const unhandled = []
        const onError = (event) => { pageErrors.push(event.error || event.message); event.preventDefault() }
        const onUnhandled = (event) => { unhandled.push(event.reason); event.preventDefault() }

        const runCase = async (kind) => {
          const primary = { seam: `${kind}-primary` }
          const cleanup = { seam: `${kind}-cleanup` }
          let factoryCalls = 0
          let failedDisconnects = 0
          let recoveredCreates = 0
          let callbacks
          let callbackThrew = false
          const recoveredRefreshAttempts = []
          const host = document.createElement("div")
          host.dataset.statusVersion = kind
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", "StatusChannel")
          source.setAttribute("signed-stream-name", `test-${kind}`)
          source.catchUpRefresh = { token: kind, location: source.statusLocation }
          if (kind === "received") source.dispatchMessageEvent = () => { throw primary }
          host.appendChild(source)
          source.createConsumer = async () => {
            factoryCalls += 1
            if (factoryCalls > 1) {
              return {
                disconnect() {},
                subscriptions: {
                  create(_channel, recoveredCallbacks) {
                    recoveredCreates += 1
                    const subscription = {
                      perform(_action, data) {
                        recoveredRefreshAttempts.push(data.refresh_attempted)
                        return true
                      },
                      unsubscribe() {}
                    }
                    queueMicrotask(() => recoveredCallbacks.connected({ reconnected: false }))
                    return subscription
                  }
                }
              }
            }
            if (kind === "consumer-rejection") throw primary

            return {
              disconnect() {
                failedDisconnects += 1
                if (kind !== "false-disconnect") throw cleanup
              },
              subscriptions: {
                create(_channel, failedCallbacks) {
                  callbacks = failedCallbacks
                  if (kind === "registration") throw primary
                  const subscription = {
                    perform() { return true },
                    unsubscribe() {
                      if (kind === "false-disconnect") throw cleanup
                    }
                  }
                  if ([ "false-disconnect", "received" ].includes(kind)) {
                    queueMicrotask(() => failedCallbacks.connected({ reconnected: false }))
                  }
                  return subscription
                }
              }
            }
          }

          const warningStart = warnings.length
          document.body.appendChild(host)
          const owner = source.statusOwner
          const failedAttempt = owner.currentAttempt
          if (kind !== "consumer-rejection") {
            const callbackDeadline = performance.now() + 1_000
            while (!callbacks && performance.now() < callbackDeadline) {
              await new Promise((resolve) => setTimeout(resolve, 0))
            }
          }
          if ([ "rejection", "false-disconnect", "received" ].includes(kind)) {
            if ([ "false-disconnect", "received" ].includes(kind)) {
              const confirmedDeadline = performance.now() + 1_000
              while (!source.hasAttribute("connected") && performance.now() < confirmedDeadline) {
                await new Promise((resolve) => setTimeout(resolve, 0))
              }
            }
            try {
              if (kind === "rejection") callbacks.rejected()
              else if (kind === "received") callbacks.received("failing payload")
              else callbacks.disconnected({ willAttemptReconnect: false })
            } catch (_error) {
              callbackThrew = true
            }
          }

          const retryDeadline = performance.now() + 1_000
          while (owner.state !== "retry_wait" && factoryCalls < 2 && performance.now() < retryDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const retrySnapshot = {
            state: owner.state,
            currentCleared: owner.currentAttempt === null,
            retired: failedAttempt?.retired || false,
            detached: failedAttempt ? failedAttempt.subscription === null && failedAttempt.consumer === null : false,
            retryOwned: Boolean(owner.retryTimer),
            warnings: warnings.length - warningStart,
            callbackThrew,
            failedDisconnects
          }
          const recoveryDeadline = performance.now() + 1_000
          while (!source.hasAttribute("connected") && performance.now() < recoveryDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const recoveredAttempt = owner.currentAttempt
          if (callbacks) {
            callbacks.connected({ reconnected: true })
            callbacks.rejected()
            callbacks.disconnected({ willAttemptReconnect: false })
          }
          const recovered = {
            connected: source.hasAttribute("connected"),
            state: owner.state,
            factoryCalls,
            recoveredCreates,
            freshAttempt: Boolean(recoveredAttempt) && recoveredAttempt !== failedAttempt,
            staleCallbacksInert: owner.currentAttempt === recoveredAttempt,
            warnings: warnings.length - warningStart,
            recoveredRefreshAttempts
          }
          host.remove()
          return { retrySnapshot, recovered }
        }

        try {
          sourceClass.retryDelay = 100
          console.warn = (...args) => warnings.push(args)
          addEventListener("error", onError)
          addEventListener("unhandledrejection", onUnhandled)
          return {
            consumerRejection: await runCase("consumer-rejection"),
            registration: await runCase("registration"),
            rejection: await runCase("rejection"),
            falseDisconnect: await runCase("false-disconnect"),
            received: await runCase("received"),
            pageErrors: pageErrors.length,
            unhandled: unhandled.length
          }
        } finally {
          removeEventListener("error", onError)
          removeEventListener("unhandledrejection", onUnhandled)
          console.warn = originalWarn
          sourceClass.retryDelay = originalDelay
        }
      })()
    JS

    %w[consumerRejection registration rejection falseDisconnect received].each do |kind|
      attempt = result.fetch(kind)
      expected_disconnects = kind == "consumerRejection" ? 0 : 1
      assert_equal({
        "state" => "retry_wait",
        "currentCleared" => true,
        "retired" => true,
        "detached" => true,
        "retryOwned" => true,
        "warnings" => 1,
        "callbackThrew" => false,
        "failedDisconnects" => expected_disconnects
      }, attempt.fetch("retrySnapshot"))
      assert_equal({
        "connected" => true,
        "state" => "connected",
        "factoryCalls" => 2,
        "recoveredCreates" => 1,
        "freshAttempt" => true,
        "staleCallbacksInert" => true,
        "warnings" => 1,
        "recoveredRefreshAttempts" => %w[falseDisconnect received].include?(kind) ? [ false ] : [ true ]
      }, attempt.fetch("recovered"))
    end
    assert_equal 0, result.fetch("pageErrors")
    assert_equal 0, result.fetch("unhandled")
  end

  test "retired attempts fence late consumers and queued open or reopen work" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        let releaseLateConsumer
        const lateConsumerPromise = new Promise((resolve) => { releaseLateConsumer = resolve })
        let rejectLateConsumer
        const rejectedConsumerPromise = new Promise((_resolve, reject) => { rejectLateConsumer = reject })
        let lateCreates = 0
        let lateDisconnects = 0
        let lateOpens = 0
        let lateReopens = 0
        const lateConnection = {
          open() { lateOpens += 1; return true },
          reopen() { lateReopens += 1; return this.open() },
          close() {}
        }
        const lateConsumer = {
          connection: lateConnection,
          disconnect() { lateDisconnects += 1 },
          subscriptions: {
            create() {
              lateCreates += 1
              return { perform() { return true }, unsubscribe() {} }
            }
          }
        }
        const delayedHost = document.createElement("div")
        delayedHost.dataset.statusVersion = "late-consumer"
        const delayedSource = document.createElement("hive-status-stream-source")
        delayedSource.setAttribute("channel", "StatusChannel")
        delayedSource.setAttribute("signed-stream-name", "test-token")
        delayedSource.createConsumer = () => lateConsumerPromise
        delayedHost.appendChild(delayedSource)
        document.body.appendChild(delayedHost)
        const delayedLifecycle = delayedSource.statusOwner
        const delayedAttempt = delayedLifecycle.currentAttempt
        delayedHost.remove()
        releaseLateConsumer(lateConsumer)

        const lateDeadline = performance.now() + 1_000
        while (lateDisconnects === 0 && performance.now() < lateDeadline) {
          await new Promise((resolve) => setTimeout(resolve, 0))
        }
        lateConnection.open()
        lateConnection.reopen()

        const originalWarn = console.warn
        const staleWarnings = []
        let rejectedResult
        try {
          const rejectedHost = document.createElement("div")
          rejectedHost.dataset.statusVersion = "late-rejection"
          const rejectedSource = document.createElement("hive-status-stream-source")
          rejectedSource.setAttribute("channel", "StatusChannel")
          rejectedSource.setAttribute("signed-stream-name", "test-token")
          rejectedSource.createConsumer = () => rejectedConsumerPromise
          rejectedHost.appendChild(rejectedSource)
          console.warn = (...args) => staleWarnings.push(args)
          document.body.appendChild(rejectedHost)
          const rejectedLifecycle = rejectedSource.statusOwner
          const rejectedAttempt = rejectedLifecycle.currentAttempt
          rejectedHost.remove()
          rejectLateConsumer(new Error("late consumer rejection"))
          const rejectionDeadline = performance.now() + 1_000
          while (staleWarnings.length === 0 && performance.now() < rejectionDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          rejectedResult = {
            state: rejectedLifecycle.state,
            retired: rejectedAttempt.retired,
            currentAttempt: Boolean(rejectedLifecycle.currentAttempt),
            warnings: staleWarnings.length
          }
        } finally {
          console.warn = originalWarn
        }

        let activeDisconnects = 0
        let activeOpens = 0
        let activeReopens = 0
        let activeUnsubscribes = 0
        const socket = { readyState: WebSocket.CLOSED, close() {} }
        const activeConnection = {
          webSocket: socket,
          open() { activeOpens += 1; return true },
          reopen() { activeReopens += 1; return this.open() },
          close() {}
        }
        let activeCallbacks
        const activeConsumer = {
          connection: activeConnection,
          disconnect() { activeDisconnects += 1 },
          subscriptions: {
            create(_channel, callbacks) {
              activeCallbacks = callbacks
              activeConnection.open()
              const subscription = {
                perform() { return true },
                unsubscribe() { activeUnsubscribes += 1 }
              }
              queueMicrotask(() => callbacks.connected({ reconnected: false }))
              return subscription
            }
          }
        }
        const activeHost = document.createElement("div")
        activeHost.dataset.statusVersion = "queued-open"
        const activeSource = document.createElement("hive-status-stream-source")
        activeSource.setAttribute("channel", "StatusChannel")
        activeSource.setAttribute("signed-stream-name", "test-token")
        activeSource.createConsumer = async () => activeConsumer
        activeHost.appendChild(activeSource)
        document.body.appendChild(activeHost)
        const activeDeadline = performance.now() + 1_000
        while (!activeSource.hasAttribute("connected") && performance.now() < activeDeadline) {
          await new Promise((resolve) => setTimeout(resolve, 0))
        }
        const activeLifecycle = activeSource.statusOwner
        const activeAttempt = activeLifecycle.currentAttempt
        const queuedOpen = activeConnection.open
        const queuedReopen = activeConnection.reopen
        activeHost.remove()
        queuedOpen()
        queuedReopen()
        activeCallbacks.connected({ reconnected: true })
        activeCallbacks.rejected()
        activeCallbacks.disconnected({ willAttemptReconnect: false })

        return {
          late: {
            state: delayedLifecycle.state,
            retired: delayedAttempt.retired,
            creates: lateCreates,
            disconnects: lateDisconnects,
            opens: lateOpens,
            reopens: lateReopens
          },
          rejected: rejectedResult,
          queued: {
            state: activeLifecycle.state,
            retired: activeAttempt.retired,
            disconnects: activeDisconnects,
            unsubscribes: activeUnsubscribes,
            opens: activeOpens,
            reopens: activeReopens,
            connectedAttribute: activeSource.hasAttribute("connected")
          }
        }
      })()
    JS

    assert_equal({
      "state" => "disconnected",
      "retired" => true,
      "creates" => 0,
      "disconnects" => 1,
      "opens" => 0,
      "reopens" => 0
    }, result.fetch("late"))
    assert_equal({
      "state" => "disconnected",
      "retired" => true,
      "currentAttempt" => false,
      "warnings" => 1
    }, result.fetch("rejected"))
    assert_equal({
      "state" => "disconnected",
      "retired" => true,
      "disconnects" => 1,
      "unsubscribes" => 1,
      "opens" => 1,
      "reopens" => 0,
      "connectedAttribute" => false
    }, result.fetch("queued"))
  end

  test "a failed setup retires before one warning and retries with a fresh attempt" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const { cable } = await import("@hotwired/turbo-rails")
        const sharedConsumer = await cable.getConsumer()
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalRetryDelay = sourceClass.retryDelay
        const originalWarn = console.warn
        const warnings = []
        let factoryCalls = 0
        let failedDisconnects = 0
        let recoveredDisconnects = 0
        let failedCallbacks
        const failedConsumer = {
          disconnect() { failedDisconnects += 1 },
          subscriptions: {
            create(_channel, callbacks) {
              failedCallbacks = callbacks
              throw new Error("registration failed")
            }
          }
        }
        const recoveredConsumer = {
          disconnect() { recoveredDisconnects += 1 },
          subscriptions: {
            create(_channel, callbacks) {
              const subscription = {
                perform() { return true },
                unsubscribe() {}
              }
              queueMicrotask(() => callbacks.connected({ reconnected: false }))
              return subscription
            }
          }
        }
        const host = document.createElement("div")
        host.dataset.statusVersion = "setup-retry"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-token")
        source.createConsumer = async () => {
          factoryCalls += 1
          return factoryCalls === 1 ? failedConsumer : recoveredConsumer
        }
        host.appendChild(source)

        try {
          sourceClass.retryDelay = 50
          console.warn = (...args) => warnings.push(args)
          document.body.appendChild(host)
          const lifecycle = source.statusOwner
          const firstAttempt = lifecycle.currentAttempt
          const retryDeadline = performance.now() + 1_000
          while (lifecycle.state !== "retry_wait" && performance.now() < retryDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const retrySnapshot = {
            state: lifecycle.state,
            firstRetired: firstAttempt.retired,
            firstConsumerCleared: firstAttempt.consumer === null,
            warningCount: warnings.length,
            timerOwned: Boolean(lifecycle.retryTimer)
          }

          const connectedDeadline = performance.now() + 1_000
          while (!source.hasAttribute("connected") && performance.now() < connectedDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const secondAttempt = lifecycle.currentAttempt
          failedCallbacks.connected({ reconnected: false })
          failedCallbacks.rejected()
          failedCallbacks.disconnected({ willAttemptReconnect: false })

          return {
            retrySnapshot,
            finalState: lifecycle.state,
            connected: source.hasAttribute("connected"),
            factoryCalls,
            failedDisconnects,
            recoveredDisconnects,
            attemptsDiffer: firstAttempt !== secondAttempt,
            consumersDiffer: failedConsumer !== secondAttempt.consumer,
            staleCallbacksInert: lifecycle.currentAttempt === secondAttempt,
            sharedUntouched: (await cable.getConsumer()) === sharedConsumer,
            retryTimer: Boolean(lifecycle.retryTimer)
          }
        } finally {
          host.remove()
          sourceClass.retryDelay = originalRetryDelay
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal({
      "state" => "retry_wait",
      "firstRetired" => true,
      "firstConsumerCleared" => true,
      "warningCount" => 1,
      "timerOwned" => true
    }, result.fetch("retrySnapshot"))
    assert_equal "connected", result.fetch("finalState")
    assert result.fetch("connected")
    assert_equal 2, result.fetch("factoryCalls")
    assert_equal 1, result.fetch("failedDisconnects")
    assert_equal 0, result.fetch("recoveredDisconnects")
    assert result.fetch("attemptsDiffer")
    assert result.fetch("consumersDiffer")
    assert result.fetch("staleCallbacksInert")
    assert result.fetch("sharedUntouched")
    refute result.fetch("retryTimer")
  end

  test "transport reconnect stays on one attempt while terminal disconnect retries fresh" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalRetryDelay = sourceClass.retryDelay
        const originalWarn = console.warn
        const warnings = []
        const consumers = []
        const callbacks = []
        const performed = []
        const unsubscribes = []
        const disconnects = []
        const makeConsumer = () => {
          const index = consumers.length
          const consumer = {
            disconnect() { disconnects.push(index) },
            subscriptions: {
              create(_channel, mixin) {
                callbacks[index] = mixin
                const subscription = {
                  perform(action, data) {
                    performed.push([ index, action, data.status_version, data.refresh_attempted ])
                    return true
                  },
                  unsubscribe() { unsubscribes.push(index) }
                }
                queueMicrotask(() => mixin.connected({ reconnected: false }))
                return subscription
              }
            }
          }
          consumers.push(consumer)
          return consumer
        }
        const host = document.createElement("div")
        host.dataset.statusVersion = "transport-reconnect"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-token")
        source.createConsumer = async () => makeConsumer()
        host.appendChild(source)

        try {
          sourceClass.retryDelay = 50
          console.warn = (...args) => warnings.push(args)
          document.body.appendChild(host)
          const lifecycle = source.statusOwner
          const firstDeadline = performance.now() + 1_000
          while (!source.hasAttribute("connected") && performance.now() < firstDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const firstAttempt = lifecycle.currentAttempt
          const firstConsumer = firstAttempt.consumer
          const firstSubscription = firstAttempt.subscription

          callbacks[0].disconnected({ willAttemptReconnect: true })
          const reconnecting = {
            state: lifecycle.state,
            sameAttempt: lifecycle.currentAttempt === firstAttempt,
            sameConsumer: firstAttempt.consumer === firstConsumer,
            sameSubscription: firstAttempt.subscription === firstSubscription,
            consumers: consumers.length,
            connected: source.hasAttribute("connected")
          }
          callbacks[0].connected({ reconnected: true })
          const reconnected = {
            state: lifecycle.state,
            sameAttempt: lifecycle.currentAttempt === firstAttempt,
            consumers: consumers.length,
            catchUps: performed.length,
            connected: source.hasAttribute("connected")
          }

          callbacks[0].disconnected({ willAttemptReconnect: false })
          const terminal = {
            state: lifecycle.state,
            firstRetired: firstAttempt.retired,
            currentCleared: lifecycle.currentAttempt === null,
            retryOwned: Boolean(lifecycle.retryTimer),
            warnings: warnings.length
          }
          const secondDeadline = performance.now() + 1_000
          while ((consumers.length < 2 || !source.hasAttribute("connected"))
            && performance.now() < secondDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const secondAttempt = lifecycle.currentAttempt

          return {
            reconnecting,
            reconnected,
            terminal,
            recovered: {
              state: lifecycle.state,
              attemptsDiffer: secondAttempt !== firstAttempt,
              consumersDiffer: secondAttempt.consumer !== firstConsumer,
              consumers: consumers.length,
              catchUps: performed.length,
              connected: source.hasAttribute("connected"),
              retryOwned: Boolean(lifecycle.retryTimer)
            },
            firstUnsubscribes: unsubscribes.filter((index) => index === 0).length,
            firstDisconnects: disconnects.filter((index) => index === 0).length
          }
        } finally {
          host.remove()
          sourceClass.retryDelay = originalRetryDelay
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal({
      "state" => "reconnecting",
      "sameAttempt" => true,
      "sameConsumer" => true,
      "sameSubscription" => true,
      "consumers" => 1,
      "connected" => false
    }, result.fetch("reconnecting"))
    assert_equal({
      "state" => "connected",
      "sameAttempt" => true,
      "consumers" => 1,
      "catchUps" => 2,
      "connected" => true
    }, result.fetch("reconnected"))
    assert_equal({
      "state" => "retry_wait",
      "firstRetired" => true,
      "currentCleared" => true,
      "retryOwned" => true,
      "warnings" => 1
    }, result.fetch("terminal"))
    assert_equal({
      "state" => "connected",
      "attemptsDiffer" => true,
      "consumersDiffer" => true,
      "consumers" => 2,
      "catchUps" => 3,
      "connected" => true,
      "retryOwned" => false
    }, result.fetch("recovered"))
    assert_equal 1, result.fetch("firstUnsubscribes")
    assert_equal 1, result.fetch("firstDisconnects")
  end

  test "transport allocation is one per source with bounded supersession overlap" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const { cable } = await import("@hotwired/turbo-rails")
        const sharedConsumer = await cable.getConsumer()
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalCreate = sourceClass.prototype.createConsumer
        const originalPendingDelay = sourceClass.pendingReleaseDelay
        const active = new Set()
        let nextId = 0
        let peak = 0
        const makeSource = (token, confirm = true) => {
          const host = document.createElement("div")
          host.dataset.statusVersion = token
          const source = document.createElement("hive-status-stream-source")
          source.dataset.testAutoConfirm = String(confirm)
          source.setAttribute("channel", "StatusChannel")
          source.setAttribute("signed-stream-name", `test-${token}`)
          host.appendChild(source)
          return { host, source }
        }

        sourceClass.pendingReleaseDelay = 30
        // Capture `this` outside the nested subscriptions object without
        // sharing it across consumers.
        sourceClass.prototype.createConsumer = async function () {
          const source = this
          const id = ++nextId
          active.add(id)
          peak = Math.max(peak, active.size)
          return {
            id,
            disconnect() { active.delete(id) },
            subscriptions: {
              create(_channel, mixin) {
                const subscription = {
                  perform() { return true },
                  unsubscribe() {}
                }
                if (source.dataset.testAutoConfirm === "true") {
                  queueMicrotask(() => mixin.connected({ reconnected: false }))
                }
                return subscription
              }
            }
          }
        }

        const superseded = makeSource("superseded", false)
        const simultaneous = []
        try {
          document.body.appendChild(superseded.host)
          const firstDeadline = performance.now() + 1_000
          while (!superseded.source.statusOwner?.currentAttempt?.subscription
            && performance.now() < firstDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const predecessorOwner = superseded.source.statusOwner
          const predecessorAttempt = predecessorOwner.currentAttempt
          const normal = active.size

          superseded.source.setAttribute("signed-stream-name", "test-middle")
          const overlapDeadline = performance.now() + 1_000
          while (active.size < 2 && performance.now() < overlapDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const middleOwner = superseded.source.statusOwner
          const middleAttempt = middleOwner.currentAttempt
          const overlap = active.size

          superseded.source.dataset.testAutoConfirm = "true"
          superseded.source.setAttribute("signed-stream-name", "test-successor")
          const repeatedOverlapDeadline = performance.now() + 1_000
          while ((!superseded.source.hasAttribute("connected") || active.size < 2)
            && performance.now() < repeatedOverlapDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const successorOwner = superseded.source.statusOwner
          const successorAttempt = successorOwner.currentAttempt
          const repeatedOverlap = active.size

          const settledDeadline = performance.now() + 1_000
          while ((active.size !== 1 || !superseded.source.hasAttribute("connected"))
            && performance.now() < settledDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const settled = active.size
          superseded.host.remove()
          const detached = active.size

          simultaneous.push(makeSource("first"), makeSource("second"))
          simultaneous.forEach(({ host }) => document.body.appendChild(host))
          const simultaneousDeadline = performance.now() + 1_000
          while ((active.size !== 2 || simultaneous.some(({ source }) => !source.hasAttribute("connected")))
            && performance.now() < simultaneousDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const simultaneousConsumers = simultaneous.map(
            ({ source }) => source.statusOwner.currentAttempt.consumer.id
          )
          const twoSources = active.size
          simultaneous.forEach(({ host }) => host.remove())

          return {
            normal,
            overlap,
            repeatedOverlap,
            settled,
            detached,
            twoSources,
            afterTwoDetach: active.size,
            peak,
            predecessorDisconnected: predecessorOwner.state === "disconnected",
            predecessorRetired: predecessorAttempt.retired,
            middleRetired: middleAttempt.retired,
            successorDifferent: successorAttempt !== predecessorAttempt &&
              successorAttempt !== middleAttempt,
            isolated: new Set(simultaneousConsumers).size === 2,
            sharedUntouched: (await cable.getConsumer()) === sharedConsumer
          }
        } finally {
          superseded.host.remove()
          simultaneous.forEach(({ host }) => host.remove())
          sourceClass.prototype.createConsumer = originalCreate
          sourceClass.pendingReleaseDelay = originalPendingDelay
        }
      })()
    JS

    assert_operator result.fetch("repeatedOverlap"), :>=, 1
    assert_operator result.fetch("repeatedOverlap"), :<=, 2
    assert_equal({
      "normal" => 1,
      "overlap" => 2,
      "settled" => 1,
      "detached" => 0,
      "twoSources" => 2,
      "afterTwoDetach" => 0,
      "peak" => 2,
      "predecessorDisconnected" => true,
      "predecessorRetired" => true,
      "middleRetired" => true,
      "successorDifferent" => true,
      "isolated" => true,
      "sharedUntouched" => true
    }, result.except("repeatedOverlap"))
  end

  test "repeated detach and reattach keeps unconfirmed transport overlap bounded" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalCreate = sourceClass.prototype.createConsumer
        const originalPendingDelay = sourceClass.pendingReleaseDelay
        const active = new Set()
        const samples = []
        let allocations = 0
        let peak = 0
        let subscriptions = 0
        const host = document.createElement("div")
        host.dataset.statusVersion = "detach-reattach-bound"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-detach-reattach-bound")
        host.appendChild(source)

        sourceClass.pendingReleaseDelay = 30
        sourceClass.prototype.createConsumer = async function () {
          const id = ++allocations
          active.add(id)
          peak = Math.max(peak, active.size)
          return {
            disconnect() { active.delete(id) },
            subscriptions: {
              create() {
                subscriptions += 1
                return { perform() { return true }, unsubscribe() {} }
              }
            }
          }
        }

        const waitForSubscriptions = async (expected) => {
          const deadline = performance.now() + 1_000
          while (subscriptions < expected && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
        }

        try {
          document.body.appendChild(host)
          await waitForSubscriptions(1)
          for (let cycle = 1; cycle <= 3; cycle += 1) {
            host.remove()
            document.body.appendChild(host)
            await waitForSubscriptions(cycle + 1)
            samples.push(active.size)
          }
          const activeAfterCycles = active.size
          host.remove()
          const settleDeadline = performance.now() + 1_000
          while (active.size > 0 && performance.now() < settleDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          return { allocations, subscriptions, samples, activeAfterCycles, peak, settled: active.size }
        } finally {
          host.remove()
          sourceClass.prototype.createConsumer = originalCreate
          sourceClass.pendingReleaseDelay = originalPendingDelay
        }
      })()
    JS

    assert_equal 4, result.fetch("allocations")
    assert_equal 4, result.fetch("subscriptions")
    assert_equal [ 2, 2, 2 ], result.fetch("samples")
    assert_equal 2, result.fetch("activeAfterCycles")
    assert_operator result.fetch("peak"), :<=, 2
    assert_equal 0, result.fetch("settled")
  end

  test "Turbo navigation replaces one dedicated transport without overlap" do
    project = create_hive_project!("status-transport-navigation-app")
    slug = create_task!(project, "Navigate with one status transport")
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    initial = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalCreate = sourceClass.prototype.createConsumer
        const probe = {
          active: new Set(),
          allocations: 0,
          disconnects: 0,
          peak: 0,
          originalCreate
        }
        window.statusNavigationTransportProbe = probe
        sourceClass.prototype.createConsumer = async function () {
          const consumer = await originalCreate.call(this)
          const id = ++probe.allocations
          probe.active.add(id)
          probe.peak = Math.max(probe.peak, probe.active.size)
          const disconnect = consumer.disconnect.bind(consumer)
          consumer.disconnect = (...args) => {
            if (probe.active.delete(id)) probe.disconnects += 1
            return disconnect(...args)
          }
          return consumer
        }

        const source = document.querySelector("#status-stream-source")
        source.attributeChangedCallback("channel", "StatusChannel", "StatusChannel-refresh")
        const deadline = performance.now() + 5_000
        while ((probe.allocations < 1 || !source.hasAttribute("connected"))
          && performance.now() < deadline) {
          await new Promise((resolve) => setTimeout(resolve, 0))
        }
        return {
          allocations: probe.allocations,
          active: probe.active.size,
          peak: probe.peak
        }
      })()
    JS
    assert_equal({ "allocations" => 1, "active" => 1, "peak" => 1 }, initial)

    find(".kanban-card[data-task-slug='#{slug}'] .kanban-card-heading a").click
    assert_current_path task_path(project, slug), wait: 10
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
    navigated = evaluate_script(<<~JS)
      (() => {
        const probe = window.statusNavigationTransportProbe
        return {
          allocations: probe.allocations,
          disconnects: probe.disconnects,
          active: probe.active.size,
          peak: probe.peak
        }
      })()
    JS
    assert_equal({
      "allocations" => 2,
      "disconnects" => 1,
      "active" => 1,
      "peak" => 1
    }, navigated)

    click_link "Repos"
    assert_current_path repos_path, wait: 10
    assert_no_selector "#status-stream-source", visible: :all
    detached = evaluate_script(<<~JS)
      (() => {
        const probe = window.statusNavigationTransportProbe
        return { disconnects: probe.disconnects, active: probe.active.size }
      })()
    JS
    assert_equal({ "disconnects" => 2, "active" => 0 }, detached)
  ensure
    if page&.current_url
      execute_script(<<~JS)
        const probe = window.statusNavigationTransportProbe
        if (probe) {
          customElements.get("hive-status-stream-source").prototype.createConsumer = probe.originalCreate
          delete window.statusNavigationTransportProbe
        }
      JS
    end
  end

  test "an asynchronous consumer setup rejection recovers through a real catch-up" do
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    with_status_catch_up_observer do |catch_ups|
      result = evaluate_script(<<~JS)
        (async () => {
          const sourceClass = customElements.get("hive-status-stream-source")
          const originalDelay = sourceClass.retryDelay
          const liveSource = document.querySelector("#status-stream-source")
          const host = document.createElement("div")
          host.dataset.statusVersion = `consumer-rejection-${crypto.randomUUID()}`
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", liveSource.getAttribute("channel"))
          source.setAttribute("signed-stream-name", liveSource.getAttribute("signed-stream-name"))
          const createConsumer = source.createConsumer.bind(source)
          let factoryCalls = 0
          source.createConsumer = async () => {
            factoryCalls += 1
            if (factoryCalls === 1) throw new Error("consumer setup failed")
            return createConsumer()
          }
          host.appendChild(source)

          try {
            sourceClass.retryDelay = 50
            document.body.appendChild(host)
            const deadline = performance.now() + 5_000
            while (!source.hasAttribute("connected") && performance.now() < deadline) {
              await new Promise((resolve) => setTimeout(resolve, 0))
            }
            return {
              connected: source.hasAttribute("connected"),
              factoryCalls,
              pageToken: host.dataset.statusVersion
            }
          } finally {
            host.remove()
            sourceClass.retryDelay = originalDelay
          }
        })()
      JS

      assert result.fetch("connected")
      assert_equal 2, result.fetch("factoryCalls")
      catch_up = wait_for_status_catch_up(catch_ups, result.fetch("pageToken"))
      assert_equal result.fetch("pageToken"), catch_up.fetch("status_version")
    end
  end

  test "a partial Action Cable registration retires and recovers through a real catch-up" do
    sign_in!
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 10

    with_status_catch_up_observer do |catch_ups|
      result = evaluate_script(<<~JS)
        (async () => {
          const sourceClass = customElements.get("hive-status-stream-source")
          const originalDelay = sourceClass.retryDelay
          const liveSource = document.querySelector("#status-stream-source")
          const host = document.createElement("div")
          host.dataset.statusVersion = `partial-registration-${crypto.randomUUID()}`
          const source = document.createElement("hive-status-stream-source")
          source.setAttribute("channel", liveSource.getAttribute("channel"))
          source.setAttribute("signed-stream-name", liveSource.getAttribute("signed-stream-name"))
          const createConsumer = source.createConsumer.bind(source)
          let factoryCalls = 0
          let failedConsumer
          let failedDisconnects = 0
          source.createConsumer = async () => {
            factoryCalls += 1
            const consumer = await createConsumer()
            if (factoryCalls !== 1) return consumer

            failedConsumer = consumer
            const disconnect = consumer.disconnect.bind(consumer)
            consumer.disconnect = (...args) => {
              failedDisconnects += 1
              return disconnect(...args)
            }
            const open = consumer.connection.open.bind(consumer.connection)
            consumer.connection.open = (...args) => {
              const result = open(...args)
              throw new Error("connection open failed after partial registration")
            }
            return consumer
          }
          host.appendChild(source)

          try {
            sourceClass.retryDelay = 50
            document.body.appendChild(host)
            const deadline = performance.now() + 5_000
            while (!source.hasAttribute("connected") && performance.now() < deadline) {
              await new Promise((resolve) => setTimeout(resolve, 0))
            }
            const recoveredConsumer = source.statusOwner?.currentAttempt?.consumer
            return {
              connected: source.hasAttribute("connected"),
              factoryCalls,
              failedDisconnects,
              failedTransportInactive: failedConsumer ? !failedConsumer.connection.isActive() : false,
              failedMonitorStopped: failedConsumer ? !failedConsumer.connection.monitor.isRunning() : false,
              consumerReplaced: Boolean(recoveredConsumer) && recoveredConsumer !== failedConsumer,
              pageToken: host.dataset.statusVersion
            }
          } finally {
            host.remove()
            sourceClass.retryDelay = originalDelay
          }
        })()
      JS

      assert result.fetch("connected")
      assert_equal 2, result.fetch("factoryCalls")
      assert_equal 1, result.fetch("failedDisconnects")
      assert result.fetch("failedTransportInactive")
      assert result.fetch("failedMonitorStopped")
      assert result.fetch("consumerReplaced")
      catch_up = wait_for_status_catch_up(catch_ups, result.fetch("pageToken"))
      assert_equal result.fetch("pageToken"), catch_up.fetch("status_version")
    end
  end

  test "a server startup rejection retries the live source" do
    sign_in!
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
    original_connected = StatusBroadcaster.method(:subscriber_connected!)
    original_disconnected = StatusBroadcaster.method(:subscriber_disconnected!)
    connect = lambda do
      attempt = counter_mutex.synchronize { attempts += 1 }
      raise ThreadError, "cannot create broadcaster" if attempt == 1

      original_connected.call
    end
    disconnect = lambda do
      original_disconnected.call
      counter_mutex.synchronize { disconnected += 1 }
    end

    with_replaced_singleton_method(StatusBroadcaster, :subscriber_connected!, connect) do
      with_replaced_singleton_method(StatusBroadcaster, :subscriber_disconnected!, disconnect) do
        with_status_catch_up_observer do |catch_ups|
          visit root_path
          assert_selector "#status-stream-source[connected]", visible: :all, wait: 10
          assert_equal 2, counter_mutex.synchronize { attempts }
          wait_for_status_subscribers(1)
          page_token = find("[data-status-version]", visible: :all)["data-status-version"]
          catch_up = wait_for_status_catch_up(catch_ups, page_token)
          assert_equal page_token, catch_up.fetch("status_version")
          refute catch_up.fetch("refresh_attempted")

          visit repos_path
          page.document.synchronize(10) do
            count = counter_mutex.synchronize { disconnected }
            raise Capybara::ElementNotFound, "recovered subscription did not release" unless count == 1
          end
        end
      end
    end

    assert_equal 1, counter_mutex.synchronize { disconnected }
  ensure
    execute_script(<<~JS, original_delay) if page&.current_url && original_delay
      customElements.get("hive-status-stream-source").retryDelay = arguments[0]
    JS
  end

  test "a deferred adapter failure reconnects the same live attempt" do
    sign_in!
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

      lifecycle = evaluate_script(<<~JS)
        (() => {
          const owner = document.querySelector("#status-stream-source").statusOwner
          return {
            state: owner.state,
            confirmations: owner.currentAttempt.confirmations,
            attempts: Boolean(owner.currentAttempt)
          }
        })()
      JS
      assert_equal "connected", lifecycle.fetch("state")
      assert_operator lifecycle.fetch("confirmations"), :>=, 1
      assert lifecycle.fetch("attempts")

      visit repos_path
      wait_for_status_subscribers(0)
    end
  end

  test "detach cancels a rejected setup retry before it can create a subscription" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        const sourceClass = customElements.get("hive-status-stream-source")
        const originalRetryDelay = sourceClass.retryDelay
        const originalWarn = console.warn
        let factoryCalls = 0
        let created = 0
        const host = document.createElement("div")
        host.dataset.statusVersion = "cancelled-retry"
        const source = document.createElement("hive-status-stream-source")
        source.setAttribute("channel", "StatusChannel")
        source.setAttribute("signed-stream-name", "test-token")
        source.createConsumer = () => {
          factoryCalls += 1
          return Promise.reject(new Error("consumer setup failed"))
        }
        host.appendChild(source)

        try {
          sourceClass.retryDelay = 100
          console.warn = () => {}
          document.body.appendChild(host)
          const lifecycle = source.statusOwner
          const deadline = performance.now() + 1_000
          while (!lifecycle.retryTimer && performance.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const timerWasOwned = Boolean(lifecycle.retryTimer)
          host.remove()
          source.createConsumer = async () => ({
            disconnect() {},
            subscriptions: {
              create() {
                created += 1
                return { unsubscribe() {}, perform() { return true } }
              }
            }
          })
          await new Promise((resolve) => setTimeout(resolve, 150))

          return {
            state: lifecycle.state,
            timerWasOwned,
            retryCleared: lifecycle.retryTimer === null,
            factoryCalls,
            created
          }
        } finally {
          host.remove()
          sourceClass.retryDelay = originalRetryDelay
          console.warn = originalWarn
        }
      })()
    JS

    assert_equal({
      "state" => "disconnected",
      "timerWasOwned" => true,
      "retryCleared" => true,
      "factoryCalls" => 1,
      "created" => 0
    }, result)
  end

  private

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
end
