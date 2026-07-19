import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["details", "item"]
  static values = { url: String, fingerprint: String }

  keydown(event) {
    if (!this.hasDetailsTarget || !this.detailsTarget.open) return

    event.stopPropagation()
    if (event.target.matches("input, textarea") && event.key !== "Escape") return

    const items = this.itemTargets.filter((item) => !item.disabled)
    const current = items.indexOf(document.activeElement)
    let destination
    if (event.key === "ArrowDown") destination = items[(current + 1) % items.length]
    if (event.key === "ArrowUp") destination = items[(current - 1 + items.length) % items.length]
    if (event.key === "Home") destination = items[0]
    if (event.key === "End") destination = items[items.length - 1]
    if (event.key === "Escape") {
      this.detailsTarget.open = false
      destination = this.detailsTarget.querySelector("summary")
    }
    if (!destination) return

    event.preventDefault()
    destination.focus()
  }

  submit(event) {
    event.preventDefault()
    const button = event.submitter
    if (!button) return

    const form = new FormData(event.currentTarget)
    this.requestMove(button.dataset.destination, {
      confirmation: button.dataset.confirmation,
      label: button.dataset.transitionLabel,
      reason: form.get("reason"),
      confirmationSlug: form.get("confirmation_slug"),
      source: "menu"
    })
  }

  moveEvent(event) {
    this.requestMove(event.detail.destination, { source: event.detail.source || "drag" })
  }

  async requestMove(destination, options = {}) {
    if (this.element.dataset.transitionPending === "true") return
    const confirmation = this.confirmationPayload(options)
    if (!confirmation) return

    this.setPending(true)
    this.announce(`${options.label || "Move"} pending`)
    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || ""
        },
        body: JSON.stringify({
          destination,
          expected_fingerprint: this.fingerprintValue,
          ...confirmation
        })
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok) throw new TransitionError(payload.message || `Move failed (${response.status})`, payload)

      this.announce(payload.state === "queued" ? "Move queued" : "Task moved")
      this.dispatch("transition-complete", {
        prefix: "board", bubbles: true,
        detail: { destination, state: payload.state, source: options.source }
      })
    } catch (error) {
      this.setPending(false)
      this.announce(error.message || "Move failed")
      this.dispatch("transition-failed", {
        prefix: "board", bubbles: true,
        detail: { destination, source: options.source, card: error.payload?.card }
      })
    }
  }

  confirmationPayload(options) {
    if (!options.confirmation || options.confirmation === "none") return {}
    if (options.confirmation === "confirm") {
      return window.confirm(`${options.label}?`) ? { confirmation: "confirmed" } : null
    }
    if (options.confirmation === "reason") {
      const reason = options.reason?.trim() || window.prompt("Reason for this transition:")?.trim()
      return reason ? { reason } : null
    }
    if (options.confirmation === "slug") {
      const confirmationSlug = options.confirmationSlug?.trim() ||
        window.prompt(`Type ${this.element.dataset.cardSlug} to confirm:`)?.trim()
      return confirmationSlug ? { confirmation_slug: confirmationSlug } : null
    }
    return null
  }

  setPending(pending) {
    this.element.dataset.transitionPending = String(pending)
    this.element.classList.toggle("is-transition-pending", pending)
    this.element.setAttribute("aria-busy", String(pending))
    this.element.querySelectorAll(".card-menu-item").forEach((button) => { button.disabled = pending })
  }

  announce(message) {
    this.element.dispatchEvent(new CustomEvent("board:announce", { bubbles: true, detail: { message } }))
  }
}

class TransitionError extends Error {
  constructor(message, payload) {
    super(message)
    this.payload = payload
  }
}
