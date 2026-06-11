import { Controller } from "@hotwired/stimulus"

// Reloads a turbo-frame on an interval. Turbo has no native timed refresh,
// so this is the one place a timer lives; everything it loads renders
// server-side through the frame.
//
// The human always wins over the poll:
// - a focused field or typed-but-unsent input inside the frame pauses it
//   (a reload REPLACES children — it would steal focus and discard input);
// - a [data-tail-follow] pane scrolled away from its bottom pauses it too
//   (the operator is reading history; reloading would yank the content out
//   from under them). At the bottom the pane follows like `tail -f`: every
//   reload re-pins it so the live end stays in view.
// Polling resumes by itself once the form is empty again or the pane is
// scrolled back to the bottom.
export default class extends Controller {
  static values = { interval: { type: Number, default: 3000 } }

  connect() {
    this.pinToBottom = this.pinToBottom.bind(this)
    this.element.addEventListener("turbo:frame-load", this.pinToBottom)
    this.pinToBottom()
    this.timer = setInterval(() => this.reloadUnlessBusy(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
    this.element.removeEventListener("turbo:frame-load", this.pinToBottom)
  }

  reloadUnlessBusy() {
    if (this.operatorBusy() || this.readerBusy()) return

    this.element.reload()
  }

  pinToBottom() {
    const pane = this.tailPane()
    if (!pane) return

    pane.scrollTop = pane.scrollHeight
    // Observable "the controller has taken over" beacon: tests (and CSS,
    // if ever needed) can wait on it instead of racing module load.
    pane.dataset.following = "true"
  }

  tailPane() {
    return this.element.querySelector("[data-tail-follow]")
  }

  // Scrolled away from the bottom = reading history. The 8px slack means
  // "close enough to the bottom counts as following" (fractional scroll
  // positions and zoom levels make exact equality unreliable).
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
