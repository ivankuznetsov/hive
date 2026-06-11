import { Controller } from "@hotwired/stimulus"

// Reloads a turbo-frame on an interval. Turbo has no native timed refresh,
// so this is the one place a timer lives; everything it loads renders
// server-side through the frame.
//
// The human always wins over the poll: a frame reload REPLACES children,
// which would steal focus mid-keystroke and discard typed-but-unsent
// answers. Skip the tick while anything inside the frame is focused or
// any field holds unsent input — polling resumes once the form is empty
// again (sent, or cleared by the operator).
export default class extends Controller {
  static values = { interval: { type: Number, default: 3000 } }

  connect() {
    this.timer = setInterval(() => this.reloadUnlessBusy(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  reloadUnlessBusy() {
    if (this.operatorBusy()) return

    this.element.reload()
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
