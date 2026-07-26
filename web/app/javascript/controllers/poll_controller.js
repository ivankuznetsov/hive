import { Controller } from "@hotwired/stimulus"

// A bounded, one-request-at-a-time poller for server-rendered turbo frames.
// It uses a chained timeout (never setInterval), pauses while the document is
// hidden or the operator is reading/editing, and installs an AbortSignal into
// Turbo's fetch options so disconnect/navigation cancels outstanding work.
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 3000 },
    maxInterval: { type: Number, default: 30000 },
    requestTimeout: { type: Number, default: 15000 }
  }

  connect() {
    this.frame = this.frameElement()
    if (!this.frame) return

    this.connected = true
    this.generation = 0
    this.failures = 0
    this.inFlight = false
    this.pinToBottom = this.pinToBottom.bind(this)
    this.requestStarted = this.requestStarted.bind(this)
    this.requestFinished = this.requestFinished.bind(this)
    this.requestFailed = this.requestFailed.bind(this)
    this.visibilityChanged = this.visibilityChanged.bind(this)

    this.frame.addEventListener("turbo:before-fetch-request", this.requestStarted)
    this.frame.addEventListener("turbo:frame-load", this.requestFinished)
    this.frame.addEventListener("turbo:fetch-request-error", this.requestFailed)
    document.addEventListener("visibilitychange", this.visibilityChanged)
    this.pinToBottom()
    this.schedule(this.intervalValue)
  }

  disconnect() {
    this.connected = false
    this.generation += 1
    this.cancelSchedule()
    this.abortRequest("disconnect")
    this.frame?.removeEventListener("turbo:before-fetch-request", this.requestStarted)
    this.frame?.removeEventListener("turbo:frame-load", this.requestFinished)
    this.frame?.removeEventListener("turbo:fetch-request-error", this.requestFailed)
    document.removeEventListener("visibilitychange", this.visibilityChanged)
    this.frame = null
  }

  schedule(delay) {
    // A hidden document owns no timer at all. In particular, aborting an
    // in-flight Turbo request can emit a later fetch-error event; that event
    // must not quietly restart a wake-up loop while the page stays hidden.
    if (!this.connected || document.hidden || this.terminal()) return

    this.cancelSchedule()
    this.timer = setTimeout(() => this.tick(), Math.max(0, delay))
  }

  cancelSchedule() {
    clearTimeout(this.timer)
    this.timer = null
  }

  tick() {
    if (!this.connected || this.terminal()) return

    // Observable in system tests and production diagnostics: paused ticks are
    // counted too, proving no hidden request loop is running.
    this.element.dataset.pollTicks = String(Number(this.element.dataset.pollTicks || 0) + 1)
    if (document.hidden || this.inFlight || this.frameBusy() || this.operatorBusy()) {
      this.schedule(this.nextDelay())
      return
    }
    if (this.readerBusy()) {
      const pane = this.tailPane()
      if (pane) pane.dataset.following = "false"
      this.schedule(this.nextDelay())
      return
    }

    this.inFlight = true
    this.generation += 1
    this.activeGeneration = this.generation
    this.requestController = new AbortController()
    this.requestDeadline = setTimeout(() => {
      if (!this.inFlight || this.activeGeneration !== this.generation) return

      this.failures += 1
      this.abortRequest("timeout")
      this.schedule(this.nextDelay())
    }, this.requestTimeoutValue)
    this.frame.reload()
  }

  requestStarted(event) {
    if (!this.inFlight || event.target !== this.frame || !this.requestController) return

    event.detail.fetchOptions.signal = this.requestController.signal
    event.detail.fetchOptions.headers = {
      ...event.detail.fetchOptions.headers,
      "X-Hive-Poll-Generation": String(this.activeGeneration)
    }
  }

  requestFinished(event) {
    if (!this.connected || event.target !== this.frame) return
    if (this.inFlight && this.activeGeneration !== this.generation) return

    this.finishRequest(true)
    this.pinToBottom()
    this.schedule(this.intervalValue)
  }

  requestFailed(event) {
    if (event.target !== this.frame) return

    this.failures += 1
    this.finishRequest(false)
    this.schedule(this.nextDelay())
  }

  finishRequest(success) {
    clearTimeout(this.requestDeadline)
    this.requestDeadline = null
    this.inFlight = false
    this.requestController = null
    if (success) this.failures = 0
  }

  abortRequest(reason) {
    if (this.requestController && !this.requestController.signal.aborted) {
      this.requestController.abort(reason)
    }
    this.finishRequest(false)
  }

  visibilityChanged() {
    if (document.hidden) {
      this.abortRequest("hidden")
      this.cancelSchedule()
    } else {
      this.schedule(0)
    }
  }

  nextDelay() {
    if (this.failures <= 0) return this.intervalValue

    return Math.min(
      this.maxIntervalValue,
      this.intervalValue * (2 ** Math.min(this.failures, 8))
    )
  }

  terminal() {
    return this.element.dataset.pollTerminal === "true" ||
      this.frame?.dataset.pollTerminal === "true"
  }

  frameBusy() {
    return !this.frame || this.frame.hasAttribute("busy") ||
      this.frame.getAttribute("aria-busy") === "true"
  }

  frameElement() {
    if (this.element.localName === "turbo-frame") return this.element
    return this.element.closest("turbo-frame")
  }

  pinToBottom() {
    const pane = this.tailPane()
    if (!pane) return

    pane.scrollTop = pane.scrollHeight
    pane.dataset.following = "true"
  }

  tailPane() {
    return this.element.querySelector("[data-tail-follow]")
  }

  readerBusy() {
    const pane = this.tailPane()
    if (!pane) return false

    return pane.scrollHeight - pane.scrollTop - pane.clientHeight > 8
  }

  operatorBusy() {
    const active = document.activeElement
    if (active && this.element.contains(active) &&
        (active.matches("input, textarea, select") || active.isContentEditable)) {
      return true
    }
    return Array.from(this.element.querySelectorAll("input:not([type=hidden]), textarea"))
      .some((field) => field.value && field.value.trim() !== "")
  }
}
