import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["region"]

  speak(event) {
    this.regionTarget.textContent = ""
    requestAnimationFrame(() => { this.regionTarget.textContent = event.detail.message || "Board updated" })
  }
}
