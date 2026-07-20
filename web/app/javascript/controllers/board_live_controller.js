import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { epoch: String, generation: Number }

  connect() {
    this.reconciling = false
    this.observer = new MutationObserver(() => this.consumeCursor())
    this.observer.observe(this.element, { childList: true })

    this.cableSource = document.querySelector("turbo-cable-stream-source")
    this.cableHasConnected = this.cableSource?.hasAttribute("connected") || false
    this.cableObserver = new MutationObserver((mutations) => this.connectionChanged(mutations))
    if (this.cableSource) {
      this.cableObserver.observe(this.cableSource, {
        attributes: true, attributeFilter: ["connected"], attributeOldValue: true
      })
    }
  }

  disconnect() {
    this.observer.disconnect()
    this.cableObserver.disconnect()
    this.finishReconciliation()
  }

  consumeCursor() {
    const frame = this.element.querySelector("#board_sync")
    if (!frame) return

    const epoch = frame.dataset.epoch
    const generation = Number(frame.dataset.generation)
    if (epoch === this.epochValue && generation === this.generationValue + 1) {
      if (frame.dataset.refreshRequired === "true") {
        this.reconcile("Board update requires a full refresh")
        return
      }
      this.generationValue = generation
      this.announce("Board updated")
      return
    }
    this.reconcile("Board updates were missed; refreshing current state")
  }

  connectionChanged(mutations) {
    let reconnected = false
    mutations.forEach((mutation) => {
      if (mutation.oldValue === null) {
        reconnected ||= this.cableHasConnected
        this.cableHasConnected = true
      }
    })
    if (reconnected) this.reconcile("Board reconnected; refreshing current state")
  }

  requested(event) {
    this.reconcile(event.detail?.message || "Task changed; refreshing current state")
  }

  reconcile(message) {
    if (this.reconciling) return
    this.reconciling = true
    this.announce(message)
    this.watchReconciliation()
    try {
      window.Turbo.visit(window.location.href, { action: "replace" })
    } catch (error) {
      this.finishReconciliation()
      throw error
    }
    window.setTimeout(() => {
      if (!this.reconcileVisitStarted) this.finishReconciliation()
    }, 0)
  }

  watchReconciliation() {
    this.reconcileVisitStarted = false
    this.visitStarted = () => { this.reconcileVisitStarted = true }
    this.visitFinished = () => this.finishReconciliation()
    document.addEventListener("turbo:visit", this.visitStarted)
    document.addEventListener("turbo:load", this.visitFinished, { once: true })
    document.addEventListener("turbo:fetch-request-error", this.visitFinished, { once: true })
  }

  finishReconciliation() {
    this.reconciling = false
    if (this.visitStarted) document.removeEventListener("turbo:visit", this.visitStarted)
    if (this.visitFinished) {
      document.removeEventListener("turbo:load", this.visitFinished)
      document.removeEventListener("turbo:fetch-request-error", this.visitFinished)
    }
    this.visitStarted = null
    this.visitFinished = null
  }

  announce(message) {
    this.element.dispatchEvent(new CustomEvent("board:announce", { bubbles: true, detail: { message } }))
  }
}
