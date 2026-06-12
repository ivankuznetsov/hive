import { Controller } from "@hotwired/stimulus"

// Reloads a turbo-frame on an interval. Turbo has no native timed refresh,
// so this is the one place a timer lives; everything it loads renders
// server-side through the frame.
//
// The human always wins over the poll:
// - a focused field or typed-but-unsent input inside the frame pauses it
//   (a reload replaces children — or morphs, when the frame opts in via
//   refresh="morph" — and either way the server renders fields empty);
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
    // Tick beacon: counts every timer firing, INCLUDING paused ones. "The
    // poll ran and chose not to touch the pane" is otherwise unobservable,
    // which made the reading-pause untestable without sleeps.
    this.element.dataset.pollTicks = String(Number(this.element.dataset.pollTicks || 0) + 1)
    if (this.operatorBusy()) return
    if (this.readerBusy()) {
      const pane = this.tailPane()
      if (pane) pane.dataset.following = "false"
      return
    }

    this.element.reload()
  }

  pinToBottom() {
    const pane = this.tailPane()
    if (!pane) return

    pane.scrollTop = pane.scrollHeight
    // Observable state beacon: "true" while pinned and following, flipped
    // to "false" by a paused tick. Tests wait on it instead of racing
    // module load or sleeping through poll intervals.
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
