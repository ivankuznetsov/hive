import { Controller } from "@hotwired/stimulus"

// Reloads a turbo-frame on an interval. Turbo has no native timed refresh,
// so this is the one place a timer lives; everything it loads renders
// server-side through the frame. Used for the log tail and the agent
// login wait — the status grid itself updates over Turbo Streams.
export default class extends Controller {
  static values = { interval: { type: Number, default: 3000 } }

  connect() {
    this.timer = setInterval(() => this.element.reload(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }
}
