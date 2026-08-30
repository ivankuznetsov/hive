import { Turbo, cable } from "@hotwired/turbo-rails"

class CleanupCollector {
  constructor() {
    this.failed = false
    this.error = undefined
  }

  capture(error) {
    if (!this.failed) {
      this.failed = true
      this.error = error
    }
  }

  run(operation) {
    try {
      return operation()
    } catch (error) {
      this.capture(error)
      return undefined
    }
  }

  rethrow() {
    if (this.failed) throw this.error
  }
}

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
    if ([ "disconnecting", "disconnected" ].includes(this.state)) return

    const cleanup = new CleanupCollector()
    this.state = "disconnecting"
    const attempt = this.currentAttempt
    this.currentAttempt = null
    this.catchUpAttempt = null
    const retryTimer = this.retryTimer
    this.retryTimer = null
    if (attempt) attempt.openAllowed = false

    this.cancelTimer(retryTimer, cleanup)

    if (attempt?.subscription && !attempt.confirmed) {
      // Subscribe and unsubscribe are independent server jobs. Until one of
      // Action Cable's disposition callbacks arrives, keep local custody so
      // an unsubscribe cannot overtake the pending subscribe.
      this.pendingReleaseDisposition = { attempt }
      if (!this.schedulePendingRelease(attempt, cleanup)) {
        this.pendingReleaseDisposition = null
        this.retireAttempt(attempt, cleanup, { transportFirst: true })
      }
    } else if (attempt) {
      this.retireAttempt(attempt, cleanup)
    }

    this.state = "disconnected"
    cleanup.rethrow()
  }

  startAttempt() {
    if (!this.isMounted() || this.currentAttempt) return

    this.source.connectTurboStreamSource()
    const attempt = {
      consumer: null,
      connection: null,
      socket: null,
      monitor: null,
      subscription: null,
      confirmations: 0,
      catchUps: 0,
      confirmed: false,
      released: false,
      retired: false,
      openAllowed: true
    }
    this.currentAttempt = attempt
    this.state = "connecting"
    void this.setupAttempt(attempt).catch((error) => {
      if (this.isCurrentAttempt(attempt)) {
        this.failAttempt(attempt, error)
      } else {
        this.retireStaleAttempt(attempt, error)
      }
    })
  }

  async setupAttempt(attempt) {
    let consumer
    try {
      consumer = await this.source.createConsumer()
    } catch (error) {
      if (this.isCurrentAttempt(attempt)) {
        this.failAttempt(attempt, error)
      } else {
        this.retireStaleAttempt(attempt, error)
      }
      return
    }

    try {
      this.installConsumer(attempt, consumer)
    } catch (error) {
      if (this.isCurrentAttempt(attempt)) {
        this.failAttempt(attempt, error)
      } else {
        this.retireStaleAttempt(attempt, error)
      }
      return
    }

    if (!this.isCurrentAttempt(attempt)) {
      this.retireStaleAttempt(attempt)
      return
    }

    try {
      const subscription = consumer.subscriptions.create(this.source.channel, {
        received: (data) => this.runAttemptCallback(
          attempt,
          () => this.received(attempt, data)
        ),
        connected: (details) => this.runAttemptCallback(
          attempt,
          () => this.subscriptionConnected(attempt, details)
        ),
        disconnected: (details = {}) => this.runAttemptCallback(
          attempt,
          () => this.subscriptionDisconnected(attempt, details)
        ),
        rejected: () => this.runAttemptCallback(
          attempt,
          () => this.subscriptionRejected(attempt)
        )
      })
      attempt.subscription = subscription
      attempt.released = false
      attempt.socket = attempt.connection?.webSocket || attempt.socket
      this.catchUp(attempt)

      if (!this.isCurrentAttempt(attempt)) {
        // A synchronous custom-element supersession can happen while a fake
        // or adapter create call is returning. The retired attempt's transport
        // is the authoritative cleanup edge, so close it before local release.
        const cleanup = new CleanupCollector()
        this.retireAttempt(attempt, cleanup, { transportFirst: true })
        this.warnCleanup("hive status subscription cleanup failed", cleanup)
      }
    } catch (error) {
      if (this.isCurrentAttempt(attempt)) {
        this.failAttempt(attempt, error)
      } else {
        this.retireStaleAttempt(attempt, error)
      }
    }
  }

  installConsumer(attempt, consumer) {
    attempt.consumer = consumer
    const connection = consumer?.connection
    attempt.connection = connection || null
    attempt.socket = connection?.webSocket || null
    attempt.monitor = connection?.monitor || null
    if (!connection) return

    if (typeof connection.open === "function") {
      const open = connection.open.bind(connection)
      connection.open = (...args) => {
        if (!this.mayOpen(attempt)) return false

        try {
          return open(...args)
        } finally {
          attempt.socket = connection.webSocket || attempt.socket
        }
      }
    }

    if (typeof connection.reopen === "function") {
      const reopen = connection.reopen.bind(connection)
      connection.reopen = (...args) => {
        if (!this.mayOpen(attempt)) return false

        try {
          return reopen(...args)
        } finally {
          attempt.socket = connection.webSocket || attempt.socket
        }
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

    const cleanup = new CleanupCollector()
    cleanup.capture(error)
    this.state = "retry_wait"
    this.catchUpAttempt = null
    this.retireAttempt(attempt, cleanup, { transportFirst: !attempt.confirmed })
    cleanup.run(() => this.source.removeAttribute("connected"))
    this.scheduleRetry(cleanup)
    this.warnCleanup("hive status subscription failed; retrying", cleanup)
  }

  failOwnerSetup(error) {
    if (this.currentAttempt) {
      this.failAttempt(this.currentAttempt, error)
      return
    }
    if (this.source.statusOwner !== this || !this.source.isConnected
      || [ "disconnecting", "disconnected" ].includes(this.state)) return

    const cleanup = new CleanupCollector()
    cleanup.capture(error)
    this.state = "retry_wait"
    this.catchUpAttempt = null
    cleanup.run(() => this.source.removeAttribute("connected"))
    this.scheduleRetry(cleanup)
    this.warnCleanup("hive status subscription failed; retrying", cleanup)
  }

  retireStaleAttempt(attempt, error) {
    const cleanup = new CleanupCollector()
    if (arguments.length > 1) cleanup.capture(error)
    this.retireAttempt(attempt, cleanup, { transportFirst: !attempt.confirmed })
    this.warnCleanup("hive status subscription cleanup failed", cleanup)
  }

  runAttemptCallback(attempt, callback) {
    try {
      callback()
    } catch (error) {
      if (this.isCurrentAttempt(attempt)) {
        this.failAttempt(attempt, error)
      } else {
        this.retireStaleAttempt(attempt, error)
      }
    }
  }

  scheduleRetry(cleanup) {
    if (!this.isRetryable() || this.retryTimer) return

    let timer
    cleanup.run(() => {
      timer = setTimeout(() => {
        if (this.retryTimer !== timer) return

        this.retryTimer = null
        if (!this.isRetryable()) return

        try {
          this.startAttempt()
        } catch (error) {
          this.failOwnerSetup(error)
        }
      }, this.source.constructor.retryDelay)
      this.retryTimer = timer
    })
  }

  schedulePendingRelease(attempt, cleanup) {
    if (!this.isPendingRelease(attempt) || this.pendingReleaseTimer) return

    let timer
    let scheduled = false
    cleanup.run(() => {
      timer = setTimeout(
        () => this.pendingReleaseTimedOut(attempt, timer),
        this.source.constructor.pendingReleaseDelay
      )
      this.pendingReleaseTimer = timer
      scheduled = true
    })
    return scheduled
  }

  pendingReleaseTimedOut(attempt, timer) {
    if (this.pendingReleaseTimer !== timer || !this.isPendingRelease(attempt)) return

    const cleanup = new CleanupCollector()
    this.pendingReleaseTimer = null
    this.pendingReleaseDisposition = null
    this.source.forgetRetiringStatusOwner(this)
    // With exclusive transport ownership the fallback needs no registry
    // scan: close first, then forget the client handle locally.
    this.retireAttempt(attempt, cleanup, { transportFirst: true })
    this.warnCleanup("hive status subscription cleanup failed", cleanup)
  }

  finishPendingRelease(attempt) {
    if (!this.isPendingRelease(attempt)) return

    const cleanup = new CleanupCollector()
    const timer = this.pendingReleaseTimer
    this.pendingReleaseTimer = null
    this.pendingReleaseDisposition = null
    this.source.forgetRetiringStatusOwner(this)
    this.cancelTimer(timer, cleanup)
    this.retireAttempt(attempt, cleanup)
    this.warnCleanup("hive status subscription cleanup failed", cleanup)
  }

  forcePendingRelease(cleanup) {
    const attempt = this.pendingReleaseDisposition?.attempt
    if (!attempt) return

    const timer = this.pendingReleaseTimer
    this.pendingReleaseTimer = null
    this.pendingReleaseDisposition = null
    this.source.forgetRetiringStatusOwner(this)
    this.cancelTimer(timer, cleanup)
    this.retireAttempt(attempt, cleanup, { transportFirst: true })
  }

  retireAttempt(attempt, cleanup, { transportFirst = false } = {}) {
    attempt.retired = true
    attempt.openAllowed = false
    if (this.currentAttempt === attempt) this.currentAttempt = null

    const subscription = attempt.subscription && !attempt.released
      ? attempt.subscription
      : null
    const consumer = attempt.consumer
    const connection = attempt.connection
    const socket = attempt.socket
    const monitor = attempt.monitor
    if (subscription) attempt.released = true
    attempt.subscription = null
    attempt.consumer = null
    attempt.connection = null
    attempt.socket = null
    attempt.monitor = null

    const releaseSubscription = () => {
      if (subscription) cleanup.run(() => subscription.unsubscribe())
    }

    const closeTransport = () => {
      if (!consumer && !connection && !socket && !monitor) return

      if (consumer) cleanup.run(() => consumer.disconnect?.())
      if (this.socketCanClose(socket, cleanup)) {
        cleanup.run(() => connection?.close?.({ allowReconnect: false }))
      }
      if (this.socketCanClose(socket, cleanup)) cleanup.run(() => socket.close?.())
      this.stopMonitor(monitor, cleanup)
    }

    // Consumer creation may still be pending when the owner retires. Leave
    // this slot closable so the late dedicated consumer is disposed on arrival.
    if (transportFirst) {
      closeTransport()
      releaseSubscription()
    } else {
      releaseSubscription()
      closeTransport()
    }
  }

  socketCanClose(socket, cleanup) {
    if (!socket) return false

    const connecting = globalThis.WebSocket?.CONNECTING ?? 0
    const open = globalThis.WebSocket?.OPEN ?? 1
    let canClose = false
    cleanup.run(() => {
      const readyState = socket.readyState
      canClose = readyState === connecting || readyState === open
    })
    return canClose
  }

  stopMonitor(monitor, cleanup) {
    if (!monitor) return

    let shouldStop = true
    cleanup.run(() => {
      if (typeof monitor.isRunning === "function") shouldStop = monitor.isRunning()
    })
    if (shouldStop) cleanup.run(() => monitor.stop?.())
  }

  cancelTimer(timer, cleanup) {
    if (timer == null) return

    cleanup.run(() => clearTimeout(timer))
  }

  warnCleanup(message, cleanup) {
    if (cleanup.failed) this.source.reportStatusFailure(message, cleanup.error)
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
    return [ "connecting", "connected", "reconnecting", "retry_wait" ].includes(this.state)
      && this.source.statusOwner === this
      && this.source.isConnected
  }

  isRetryable() {
    return this.state === "retry_wait"
      && this.source.statusOwner === this
      && this.source.isConnected
  }

  isCurrentAttempt(attempt) {
    return this.isMounted() && this.currentAttempt === attempt && !attempt.retired
  }

  isPendingRelease(attempt) {
    return [ "disconnecting", "disconnected" ].includes(this.state)
      && this.pendingReleaseDisposition?.attempt === attempt
      && !attempt.retired
  }
}

class HiveStatusStreamSourceElement extends HTMLElement {
  static observedAttributes = ["channel", "signed-stream-name"]
  static retryDelay = 5_000
  static pendingReleaseDelay = 5_000

  connectedCallback() {
    if (!this.isConnected) return
    if (this.statusOwner && this.statusOwner.state !== "disconnected") return

    if (this.catchUpRefresh?.location !== undefined
      && this.catchUpRefresh.location !== this.statusLocation) {
      this.clearCatchUpRefresh()
    }

    const owner = new StatusStreamOwner(this)
    this.statusOwner = owner
    try {
      owner.connect()
    } catch (error) {
      owner.failOwnerSetup(error)
    }
  }

  disconnectedCallback() {
    const owner = this.statusOwner
    this.statusOwner = null
    const cleanup = new CleanupCollector()
    const retiringOwner = this.statusRetiringOwner
    this.statusRetiringOwner = null
    if (retiringOwner && retiringOwner !== owner) retiringOwner.forcePendingRelease(cleanup)
    cleanup.run(() => this.disconnectTurboStreamSource())
    if (owner) cleanup.run(() => owner.disconnect())
    if (owner?.pendingReleaseDisposition) this.statusRetiringOwner = owner
    cleanup.run(() => this.removeAttribute("connected"))
    if (cleanup.failed) {
      this.reportStatusFailure("hive status subscription disconnect failed", cleanup.error)
    }
  }

  attributeChangedCallback(_name, oldValue, newValue) {
    if (!this.isConnected || oldValue === null || oldValue === newValue) return

    const previousWarnings = this.statusWarningQueue
    const deferredWarnings = []
    this.statusWarningQueue = deferredWarnings

    const owner = this.statusOwner
    this.statusOwner = null
    const oldCleanup = new CleanupCollector()
    try {
      const retiringOwner = this.statusRetiringOwner
      this.statusRetiringOwner = null
      if (retiringOwner && retiringOwner !== owner) retiringOwner.forcePendingRelease(oldCleanup)
      oldCleanup.run(() => this.disconnectTurboStreamSource())
      if (owner) oldCleanup.run(() => owner.disconnect())
      if (owner?.pendingReleaseDisposition) this.statusRetiringOwner = owner
      oldCleanup.run(() => this.removeAttribute("connected"))

      if (!this.statusOwner) {
        const successorSetup = new CleanupCollector()
        successorSetup.run(() => this.connectedCallback())
        if (successorSetup.failed) {
          if (!this.statusOwner) {
            const successor = new StatusStreamOwner(this)
            this.statusOwner = successor
            successor.failOwnerSetup(successorSetup.error)
          } else {
            this.reportStatusFailure(
              "hive status subscription failed; retrying",
              successorSetup.error
            )
          }
        }
      }
    } finally {
      this.statusWarningQueue = previousWarnings
      const warnings = []
      if (oldCleanup.failed) {
        warnings.push({
          message: "hive status subscription disconnect failed",
          error: oldCleanup.error
        })
      }
      warnings.push(...deferredWarnings)
      this.publishStatusWarnings(warnings)
    }
  }

  connectTurboStreamSource() {
    return Turbo.connectStreamSource(this)
  }

  disconnectTurboStreamSource() {
    return Turbo.disconnectStreamSource(this)
  }

  forgetRetiringStatusOwner(owner) {
    if (this.statusRetiringOwner === owner) this.statusRetiringOwner = null
  }

  reportStatusFailure(message, error) {
    const warning = { message, error }
    if (this.statusWarningQueue) {
      this.statusWarningQueue.push(warning)
    } else {
      this.publishStatusWarnings([ warning ])
    }
  }

  publishStatusWarnings(warnings) {
    if (this.statusWarningQueue) {
      this.statusWarningQueue.push(...warnings)
      return
    }

    const reported = []
    warnings.forEach(({ message, error }) => {
      if (reported.some((reportedError) => Object.is(reportedError, error))) return

      reported.push(error)
      try {
        console.warn(message, error)
      } catch (_warningError) {
        // A diagnostic failure must not escape a custom-element reaction.
      }
    })
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
