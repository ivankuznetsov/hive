import { Controller } from "@hotwired/stimulus"

// Stimulus can disconnect while Turbo preserves the Cable source, and Turbo's
// history cache can later restore a clone of it. A source-owned attribute
// survives both paths but is absent from fresh server markup, so a reconnect
// is never confused with either page boot or another page's first connection.
const CONNECTED_ONCE_ATTRIBUTE = "status-connected-once"

// A status refresh has no Turbo request ID because it comes from a background
// filesystem subscriber. Defer it while any form in this status surface is
// submitting so the refresh cannot abort a mutation after the server writes.
export default class extends Controller {
  connect() {
    this.inFlightForms = new Set()
    this.refreshPending = false
    this.redirecting = false
    this.streamSource = this.element.querySelector("turbo-cable-stream-source")
    this.cableConnected = this.streamSource?.hasAttribute("connected") || false
    if (this.cableConnected) this.streamSource.setAttribute(CONNECTED_ONCE_ATTRIBUTE, "")
    this.connectionObserver = new MutationObserver(this.connectionChanged.bind(this))
    if (this.streamSource) {
      this.connectionObserver.observe(this.streamSource, {
        attributes: true,
        attributeFilter: ["connected"],
        attributeOldValue: true
      })
    }
  }

  disconnect() {
    this.connectionObserver.disconnect()
    this.inFlightForms.clear()
  }

  submitting(event) {
    if (this.element.contains(event.target)) this.inFlightForms.add(event.target)
  }

  submitted(event) {
    this.inFlightForms.delete(event.target)
    if (this.inFlightForms.size > 0) return

    // A successful redirected mutation already reconciles from a fresh GET.
    // Replaying against the old URL during Turbo's redirect handoff can race
    // and incorrectly pull the operator back to the page they just left.
    if (event.detail?.success && event.detail?.fetchResponse?.redirected) {
      this.refreshPending = false
      this.redirecting = true
      return
    }

    if (!this.refreshPending) return

    this.refreshPending = false
    this.replayRefresh()
  }

  beforeStreamRender(event) {
    const stream = event.detail?.newStream || event.target
    if (stream?.getAttribute("action") !== "refresh") return
    if (this.redirecting) {
      event.preventDefault()
      return
    }
    if (this.inFlightForms.size === 0) return

    this.refreshPending = true
    event.preventDefault()
  }

  connectionChanged(records) {
    for (const record of records) {
      // Turbo Cable only adds/removes this boolean attribute. Reading the
      // old value lets us process a batched disconnect+reconnect in order.
      const connected = record.oldValue === null
      if (connected && !this.cableConnected) {
        const reconnect = this.streamSource.hasAttribute(CONNECTED_ONCE_ATTRIBUTE)
        this.streamSource.setAttribute(CONNECTED_ONCE_ATTRIBUTE, "")
        if (reconnect) this.requestRefresh()
      }

      this.cableConnected = connected
    }
  }

  requestRefresh() {
    if (this.redirecting) return

    if (this.inFlightForms.size > 0) {
      this.refreshPending = true
    } else {
      this.replayRefresh()
    }
  }

  replayRefresh() {
    const stream = document.createElement("turbo-stream")
    stream.setAttribute("action", "refresh")
    document.documentElement.appendChild(stream)
  }
}
