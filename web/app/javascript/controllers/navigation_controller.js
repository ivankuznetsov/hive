import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle"]

  toggle() {
    this.toggleTarget.setAttribute("aria-expanded", this.toggleTarget.getAttribute("aria-expanded") !== "true")
  }

  close() {
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", "false")
  }

  dismiss() {
    if (!this.hasToggleTarget || this.toggleTarget.getAttribute("aria-expanded") !== "true") return
    this.close()
    this.toggleTarget.focus()
  }

  navigate(event) {
    if (event.target.closest("a, button")) this.close()
  }
}
