import { Turbo, cable } from "@hotwired/turbo-rails"

// A StatusChannel subscription owns real server work, so its client handle
// must have one unambiguous DOM owner. turbo-rails 2.0.23 assigns that handle
// only after awaiting consumer setup; if the element disconnects first, the
// late handle is otherwise left registered until the whole socket closes.
class HiveStatusStreamSourceElement extends HTMLElement {
  static observedAttributes = ["channel", "signed-stream-name"]
  static retryDelay = 5_000
  static pendingReleaseDelay = 5_000

  connectedCallback() {
    if (this.catchUpRefresh?.location !== undefined
      && this.catchUpRefresh.location !== this.statusLocation) {
      this.clearCatchUpRefresh()
    }

    Turbo.connectStreamSource(this)

    const connection = {
      confirmations: 0,
      catchUps: 0,
      refreshAttempt: null,
      confirmed: false,
      cancelled: false
    }
    this.statusConnection = connection
    this.subscribe(connection)
  }

  disconnectedCallback() {
    Turbo.disconnectStreamSource(this)

    const connection = this.statusConnection
    this.statusConnection = null
    clearTimeout(connection?.retryTimer)
    if (connection) connection.retryTimer = null
    this.cancelSubscription(connection)
    this.removeAttribute("connected")
  }

  attributeChangedCallback(_name, oldValue, newValue) {
    if (!this.isConnected || oldValue === null || oldValue === newValue) return

    this.disconnectedCallback()
    this.connectedCallback()
  }

  dispatchMessageEvent(data) {
    this.rememberCatchUpRefresh(data)
    return this.dispatchEvent(new MessageEvent("message", { data }))
  }

  async subscribe(connection) {
    let consumer
    try {
      consumer = await cable.getConsumer()
    } catch (error) {
      // turbo-rails caches the lazy consumer promise before it settles. A
      // rejection therefore poisons every later getConsumer call unless the
      // failed cache entry is explicitly released.
      cable.setConsumer(undefined)
      this.scheduleRetry(connection, error)
      return
    }

    if (this.statusConnection !== connection || !this.isConnected) return

    connection.consumer = consumer
    const subscriptionsBefore = new Set(consumer.subscriptions.subscriptions || [])
    try {
      const subscription = consumer.subscriptions.create(this.channel, {
        received: this.dispatchMessageEvent.bind(this),
        connected: () => this.subscriptionConnected(connection),
        disconnected: () => this.subscriptionDisconnected(connection),
        rejected: () => this.subscriptionRejected(connection)
      })
      connection.subscription = subscription
      connection.released = false
      this.catchUp(connection)

      if (this.statusConnection !== connection || !this.isConnected) this.cancelSubscription(connection)
    } catch (error) {
      this.releaseFailedConsumer(consumer, subscriptionsBefore)
      this.scheduleRetry(connection, error)
    }
  }

  releaseFailedConsumer(consumer, subscriptionsBefore) {
    const subscriptions = consumer.subscriptions.subscriptions || []
    for (const subscription of [...subscriptions]) {
      if (!subscriptionsBefore.has(subscription)) subscription.unsubscribe()
    }

    // Subscriptions#create registers before opening the socket. If opening
    // throws, the consumer can no longer be trusted to own another attempt.
    consumer.disconnect()
    cable.setConsumer(undefined)
  }

  scheduleRetry(connection, error) {
    if (this.statusConnection !== connection || !this.isConnected) return

    console.warn("hive status subscription failed; retrying", error)
    connection.retryTimer = setTimeout(() => {
      connection.retryTimer = null
      this.subscribe(connection)
    }, this.constructor.retryDelay)
  }

  rememberCatchUpRefresh(data) {
    if (typeof data !== "string" || !data.includes("data-status-catch-up-for")) return

    const template = document.createElement("template")
    template.innerHTML = data
    const refresh = template.content.querySelector(
      'turbo-stream[action="refresh"][data-status-catch-up-for]'
    )
    if (refresh) {
      // Keep the handoff on the live permanent element, not in cloneable DOM
      // attributes. A same-URL Turbo morph preserves this element and its
      // property; a cached snapshot restored after visiting a source-less page
      // creates a fresh element and therefore cannot revive an old attempt.
      this.catchUpRefresh = {
        token: refresh.dataset.statusCatchUpFor,
        location: this.statusLocation
      }
    }
  }

  subscriptionConnected(connection) {
    this.clearPendingRelease(connection)
    connection.confirmed = true
    connection.confirmations += 1
    if (connection.cancelled || this.statusConnection !== connection || !this.isConnected) {
      this.releaseSubscription(connection)
      return
    }

    this.setAttribute("connected", "")
    this.catchUp(connection)
  }

  subscriptionDisconnected(connection) {
    connection.confirmed = false
    if (connection.cancelled) {
      this.releaseSubscription(connection)
      return
    }
    if (this.statusConnection !== connection) return

    this.removeAttribute("connected")
    connection.refreshAttempt = null
    this.clearCatchUpRefresh()
  }

  subscriptionRejected(connection) {
    // Action Cable forgets a rejected subscription before invoking this
    // callback, so there is no unsubscribe command left to send.
    this.clearPendingRelease(connection)
    connection.confirmed = false
    connection.released = true
    connection.subscription = null
    if (this.statusConnection !== connection || !this.isConnected) return

    this.removeAttribute("connected")
    this.scheduleRetry(connection, new Error("status subscription rejected"))
  }

  clearCatchUpRefresh() {
    this.catchUpRefresh = null
  }

  cancelSubscription(connection) {
    if (!connection) return

    connection.cancelled = true
    // Action Cable processes subscribe/unsubscribe commands on independent
    // worker-pool jobs. Before confirmation, removing the client handle can
    // therefore overtake server registration and strand a channel. Keep the
    // handle until confirmation; the callback then releases it in order.
    if (connection.confirmed) {
      this.releaseSubscription(connection)
    } else {
      this.schedulePendingRelease(connection)
    }
  }

  schedulePendingRelease(connection) {
    if (!connection.subscription || connection.pendingReleaseTimer) return

    connection.pendingReleaseTimer = setTimeout(() => {
      connection.pendingReleaseTimer = null
      this.forceReleasePendingSubscription(connection)
    }, this.constructor.pendingReleaseDelay)
  }

  clearPendingRelease(connection) {
    clearTimeout(connection.pendingReleaseTimer)
    connection.pendingReleaseTimer = null
  }

  forceReleasePendingSubscription(connection) {
    if (!connection.subscription || connection.released) return

    const subscription = connection.subscription
    const registered = connection.consumer?.subscriptions?.subscriptions || []
    const replacement = registered.some((candidate) => (
      candidate !== subscription && candidate.identifier === subscription.identifier
    ))
    if (!replacement) {
      // Hive owns the only Cable subscription in this app. Closing a transport
      // that never confirmed gives the server an authoritative cleanup edge;
      // a plain unsubscribe could still overtake its pending subscribe job.
      connection.consumer?.disconnect?.()
      try {
        connection.consumer?.connection?.webSocket?.close?.()
      } catch (_error) {
        // The socket may already have crossed into CLOSED between the checks.
      }
    }
    this.releaseSubscription(connection)
  }

  releaseSubscription(connection) {
    if (!connection.subscription || connection.released) return

    this.clearPendingRelease(connection)
    const subscription = connection.subscription
    connection.released = true
    connection.subscription = null
    subscription.unsubscribe()
  }

  catchUp(connection) {
    if (this.statusConnection !== connection || !this.isConnected) return
    if (!connection.subscription || connection.catchUps >= connection.confirmations) return

    const statusVersion = this.statusVersion
    const statusLocation = this.statusLocation
    const persistentAttempt = this.catchUpRefresh?.location === statusLocation
    const connectionAttempt = connection.refreshAttempt?.location === statusLocation
    const refreshAttempted = persistentAttempt || connectionAttempt
    if (connection.subscription.perform("catch_up", {
      status_version: statusVersion,
      refresh_attempted: refreshAttempted
    })) {
      connection.refreshAttempt = refreshAttempted
        ? { location: statusLocation }
        : null
      // The element property survives the same-URL Turbo permanent move long
      // enough to hand the latch to the replacement connection. Once any
      // catch-up is sent, keeping it could suppress a later recovery.
      this.clearCatchUpRefresh()
      connection.catchUps = connection.confirmations
    }
  }

  get statusVersion() {
    return this.closest("[data-status-version]")?.dataset.statusVersion
  }

  get statusLocation() {
    return `${window.location.pathname}${window.location.search}`
  }

  get channel() {
    return {
      channel: this.getAttribute("channel"),
      signed_stream_name: this.getAttribute("signed-stream-name")
    }
  }
}

if (customElements.get("hive-status-stream-source") === undefined) {
  customElements.define("hive-status-stream-source", HiveStatusStreamSourceElement)
}
