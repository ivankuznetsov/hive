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
            window.pendingStatusLifecycleOwner = source.statusOwner
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
            create() {
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
            retryTimer: Boolean(lifecycle.retryTimer)
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
      "retryTimer" => false
    }, result)
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

  test "retired attempts fence late consumers and queued open or reopen work" do
    sign_in!
    visit repos_path

    result = evaluate_script(<<~JS)
      (async () => {
        let releaseLateConsumer
        const lateConsumerPromise = new Promise((resolve) => { releaseLateConsumer = resolve })
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

          superseded.source.dataset.testAutoConfirm = "true"
          superseded.source.setAttribute("signed-stream-name", "test-successor")
          const overlapDeadline = performance.now() + 1_000
          while (active.size < 2 && performance.now() < overlapDeadline) {
            await new Promise((resolve) => setTimeout(resolve, 0))
          }
          const successorOwner = superseded.source.statusOwner
          const successorAttempt = successorOwner.currentAttempt
          const overlap = active.size

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
            settled,
            detached,
            twoSources,
            afterTwoDetach: active.size,
            peak,
            predecessorDisconnected: predecessorOwner.state === "disconnected",
            predecessorRetired: predecessorAttempt.retired,
            successorDifferent: successorAttempt !== predecessorAttempt,
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
      "successorDifferent" => true,
      "isolated" => true,
      "sharedUntouched" => true
    }, result)
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
end
