import { Turbo, cable } from "@hotwired/turbo-rails"

// One owner contains every application-level status lifecycle resource. Each
// setup attempt receives its own consumer; Action Cable transport reconnects
// stay on that attempt, while application retries replace it.
class StatusStreamOwner {
  constructor(source) {
    this.source = source
    this.state = "connecting"
    this.currentAttempt = null
    this.retryTimer = null
    this.pendingReleaseTimer = null
    this.pendingReleaseDisposition = null
    this.catchUpAttempt = null
  }

  connect() {
    this.startAttempt()
  }

  disconnect() {
    if (this.state === "disconnected") return

    this.state = "disconnected"
    this.clearRetryTimer()
    const attempt = this.currentAttempt
    this.currentAttempt = null
    if (!attempt) return

    attempt.openAllowed = false
    if (attempt.subscription && !attempt.confirmed) {
      // Subscribe and unsubscribe are independent server jobs. Until one of
      // Action Cable's disposition callbacks arrives, keep local custody so
      // an unsubscribe cannot overtake the pending subscribe.
      this.pendingReleaseDisposition = { attempt }
      this.schedulePendingRelease(attempt)
    } else {
      this.releaseAndRetire(attempt)
    }
  }

  startAttempt() {
    if (!this.isMounted() || this.currentAttempt) return

    const attempt = {
      id: Symbol("status-stream-attempt"),
      consumer: null,
      connection: null,
      socket: null,
      subscription: null,
      confirmations: 0,
      catchUps: 0,
      confirmed: false,
      released: false,
      retired: false,
      openAllowed: true,
      transportClosed: false
    }
    this.currentAttempt = attempt
    this.state = "connecting"
    void this.setupAttempt(attempt)
  }

  async setupAttempt(attempt) {
    let consumer
    try {
      consumer = await this.source.createConsumer()
    } catch (error) {
      this.failAttempt(attempt, error)
      return
    }

    this.installConsumer(attempt, consumer)
    if (!this.isCurrentAttempt(attempt)) {
      attempt.retired = true
      attempt.openAllowed = false
      this.closeTransport(attempt)
      return
    }

    try {
      const subscription = consumer.subscriptions.create(this.source.channel, {
        received: (data) => this.received(attempt, data),
        connected: (details) => this.subscriptionConnected(attempt, details),
        disconnected: (details = {}) => this.subscriptionDisconnected(attempt, details),
        rejected: () => this.subscriptionRejected(attempt)
      })
      attempt.subscription = subscription
      attempt.released = false
      attempt.socket = attempt.connection?.webSocket || attempt.socket
      this.catchUp(attempt)

      if (!this.isCurrentAttempt(attempt)) {
        // A synchronous custom-element supersession can happen while a fake
        // or adapter create call is returning. The retired attempt's transport
        // is the authoritative cleanup edge, so close it before local release.
        attempt.retired = true
        attempt.openAllowed = false
        this.closeTransport(attempt)
        this.releaseSubscription(attempt)
      }
    } catch (error) {
      this.failAttempt(attempt, error)
    }
  }

  installConsumer(attempt, consumer) {
    attempt.consumer = consumer
    const connection = consumer?.connection
    attempt.connection = connection || null
    attempt.socket = connection?.webSocket || null
    if (!connection) return

    if (typeof connection.open === "function") {
      const open = connection.open.bind(connection)
      connection.open = (...args) => {
        if (!this.mayOpen(attempt)) return false

        const result = open(...args)
        attempt.socket = connection.webSocket || attempt.socket
        return result
      }
    }

    if (typeof connection.reopen === "function") {
      const reopen = connection.reopen.bind(connection)
      connection.reopen = (...args) => {
        if (!this.mayOpen(attempt)) return false

        const result = reopen(...args)
        attempt.socket = connection.webSocket || attempt.socket
        return result
      }
    }
  }

  mayOpen(attempt) {
    return attempt.openAllowed && this.isCurrentAttempt(attempt)
      && [ "connecting", "connected", "reconnecting" ].includes(this.state)
  }

  received(attempt, data) {
    if (!this.isCurrentAttempt(attempt)) return

    this.source.dispatchMessageEvent(data)
  }

  subscriptionConnected(attempt, _details = {}) {
    if (this.isPendingRelease(attempt)) {
      attempt.confirmed = true
      this.finishPendingRelease(attempt)
      return
    }
    if (!this.isCurrentAttempt(attempt)) return

    attempt.confirmed = true
    attempt.confirmations += 1
    this.state = "connected"
    this.source.setAttribute("connected", "")
    this.catchUp(attempt)
  }

  subscriptionDisconnected(attempt, { willAttemptReconnect = true } = {}) {
    if (this.isPendingRelease(attempt)) {
      this.finishPendingRelease(attempt)
      return
    }
    if (!this.isCurrentAttempt(attempt)) return

    attempt.confirmed = false
    this.source.removeAttribute("connected")
    this.catchUpAttempt = null
    this.source.clearCatchUpRefresh()
    if (willAttemptReconnect) {
      this.state = "reconnecting"
    } else {
      this.failAttempt(attempt, new Error("status subscription disconnected"))
    }
  }

  subscriptionRejected(attempt) {
    if (this.isPendingRelease(attempt)) {
      // Action Cable forgets a rejected subscription before notifying it.
      attempt.confirmed = false
      attempt.released = true
      attempt.subscription = null
      this.finishPendingRelease(attempt)
      return
    }
    if (!this.isCurrentAttempt(attempt)) return

    attempt.confirmed = false
    attempt.released = true
    attempt.subscription = null
    this.failAttempt(attempt, new Error("status subscription rejected"))
  }

  failAttempt(attempt, error) {
    if (!this.isCurrentAttempt(attempt)) return

    this.currentAttempt = null
    attempt.openAllowed = false
    this.releaseAndRetire(attempt)
    if (!this.isMounted()) return

    this.state = "retry_wait"
    this.source.removeAttribute("connected")
    this.catchUpAttempt = null
    this.source.clearCatchUpRefresh()
    this.scheduleRetry(error)
  }

  scheduleRetry(error) {
    if (!this.isMounted() || this.state !== "retry_wait" || this.retryTimer) return

    console.warn("hive status subscription failed; retrying", error)
    const timer = setTimeout(() => {
      if (this.retryTimer !== timer) return

      this.retryTimer = null
      if (!this.isMounted() || this.state !== "retry_wait") return

      this.startAttempt()
    }, this.source.constructor.retryDelay)
    this.retryTimer = timer
  }

  clearRetryTimer() {
    clearTimeout(this.retryTimer)
    this.retryTimer = null
  }

  schedulePendingRelease(attempt) {
    if (!this.isPendingRelease(attempt) || this.pendingReleaseTimer) return

    const timer = setTimeout(() => {
      if (this.pendingReleaseTimer !== timer || !this.isPendingRelease(attempt)) return

      this.pendingReleaseTimer = null
      this.pendingReleaseDisposition = null
      // With exclusive transport ownership the fallback needs no registry
      // scan: close first, then forget the client handle locally.
      this.retireAttempt(attempt)
      this.releaseSubscription(attempt)
    }, this.source.constructor.pendingReleaseDelay)
    this.pendingReleaseTimer = timer
  }

  finishPendingRelease(attempt) {
    if (!this.isPendingRelease(attempt)) return

    this.clearPendingReleaseTimer()
    this.pendingReleaseDisposition = null
    this.releaseAndRetire(attempt)
  }

  clearPendingReleaseTimer() {
    clearTimeout(this.pendingReleaseTimer)
    this.pendingReleaseTimer = null
  }

  releaseAndRetire(attempt) {
    this.releaseSubscription(attempt)
    this.retireAttempt(attempt)
  }

  releaseSubscription(attempt) {
    if (!attempt.subscription || attempt.released) return

    const subscription = attempt.subscription
    attempt.released = true
    attempt.subscription = null
    subscription.unsubscribe()
  }

  retireAttempt(attempt) {
    if (attempt.retired) return

    attempt.retired = true
    attempt.openAllowed = false
    if (this.currentAttempt === attempt) this.currentAttempt = null
    this.closeTransport(attempt)
  }

  closeTransport(attempt) {
    if (attempt.transportClosed) return

    const consumer = attempt.consumer
    const connection = attempt.connection
    const socket = attempt.socket || connection?.webSocket
    // Consumer creation may still be pending when the owner retires. Leave
    // this slot closable so the late dedicated consumer is disposed on arrival.
    if (!consumer && !connection && !socket) return

    attempt.transportClosed = true
    attempt.consumer = null
    attempt.connection = null
    attempt.socket = null

    consumer?.disconnect?.()
    if (this.socketCanClose(socket)) connection?.close?.({ allowReconnect: false })
    if (this.socketCanClose(socket)) socket.close?.()
  }

  socketCanClose(socket) {
    if (!socket) return false

    const connecting = globalThis.WebSocket?.CONNECTING ?? 0
    const open = globalThis.WebSocket?.OPEN ?? 1
    return socket.readyState === connecting || socket.readyState === open
  }

  catchUp(attempt) {
    if (!this.isCurrentAttempt(attempt)) return
    if (!attempt.subscription || attempt.catchUps >= attempt.confirmations) return

    const statusVersion = this.source.statusVersion
    const statusLocation = this.source.statusLocation
    const persistentAttempt = this.source.catchUpRefresh?.location === statusLocation
    const connectionAttempt = this.catchUpAttempt?.location === statusLocation
    const refreshAttempted = persistentAttempt || connectionAttempt
    if (attempt.subscription.perform("catch_up", {
      status_version: statusVersion,
      refresh_attempted: refreshAttempted
    })) {
      this.catchUpAttempt = refreshAttempted ? { location: statusLocation } : null
      // The permanent element property hands a same-URL refresh latch to a new
      // owner. Once a catch-up is sent, keeping it could suppress later recovery.
      this.source.clearCatchUpRefresh()
      attempt.catchUps = attempt.confirmations
    }
  }

  isMounted() {
    return this.state !== "disconnected"
      && this.source.statusOwner === this
      && this.source.isConnected
  }

  isCurrentAttempt(attempt) {
    return this.isMounted() && this.currentAttempt === attempt && !attempt.retired
  }

  isPendingRelease(attempt) {
    return this.state === "disconnected"
      && this.pendingReleaseDisposition?.attempt === attempt
      && !attempt.retired
  }
}

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
    const owner = new StatusStreamOwner(this)
    this.statusOwner = owner
    owner.connect()
  }

  disconnectedCallback() {
    Turbo.disconnectStreamSource(this)

    const owner = this.statusOwner
    this.statusOwner = null
    owner?.disconnect()
    this.removeAttribute("connected")
  }

  attributeChangedCallback(_name, oldValue, newValue) {
    if (!this.isConnected || oldValue === null || oldValue === newValue) return

    this.disconnectedCallback()
    this.connectedCallback()
  }

  createConsumer() {
    return cable.createConsumer()
  }

  dispatchMessageEvent(data) {
    this.rememberCatchUpRefresh(data)
    return this.dispatchEvent(new MessageEvent("message", { data }))
  }

  rememberCatchUpRefresh(data) {
    if (typeof data !== "string" || !data.includes("data-status-catch-up-for")) return

    const template = document.createElement("template")
    template.innerHTML = data
    const refresh = template.content.querySelector(
      'turbo-stream[action="refresh"][data-status-catch-up-for]'
    )
    if (refresh) {
      this.catchUpRefresh = {
        token: refresh.dataset.statusCatchUpFor,
        location: this.statusLocation
      }
    }
  }

  clearCatchUpRefresh() {
    this.catchUpRefresh = null
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
