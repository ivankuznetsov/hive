import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { epoch: String, generation: Number }

  connect() {
    this.reconciling = false
    this.observer = new MutationObserver(() => this.consumeCursor())
    this.observer.observe(this.element, { childList: true })
  }

  disconnect() {
    this.observer.disconnect()
  }

  consumeCursor() {
    const frame = this.element.querySelector("#board_sync")
    if (!frame) return

    const epoch = frame.dataset.epoch
    const generation = Number(frame.dataset.generation)
    if (epoch === this.epochValue && generation === this.generationValue + 1) {
      if (frame.dataset.refreshRequired === "true") {
        this.announce("Board update is reconciling")
        return
      }
      this.generationValue = generation
      this.announce("Board updated")
      return
    }
    this.reconcile()
  }

  reconcile() {
    if (this.reconciling) return
    this.reconciling = true
    this.announce("Board connection changed; refreshing current state")
    window.Turbo.visit(window.location.href, { action: "replace" })
  }

  announce(message) {
    this.element.dispatchEvent(new CustomEvent("board:announce", { bubbles: true, detail: { message } }))
  }
}
