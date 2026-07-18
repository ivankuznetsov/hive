import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame"]

  connect() {
    if (this.hasFrameTarget && this.frameTarget.innerHTML.trim()) this.markOpen(false)
  }

  disconnect() {
    document.body.classList.remove("drawer-open")
  }

  remember(event) {
    const card = event.currentTarget.closest(".board-card")
    if (card?.id) this.frameTarget.dataset.returnFocusId = card.id
  }

  opened(event) {
    if (event.target !== this.frameTarget || !this.frameTarget.innerHTML.trim()) return

    this.markOpen(true)
  }

  close(event) {
    event?.preventDefault()
    if (!this.hasFrameTarget) return

    const returnId = this.frameTarget.dataset.returnFocusId
    this.frameTarget.replaceChildren()
    this.frameTarget.classList.remove("is-open")
    document.body.classList.remove("drawer-open")
    if (returnId) document.getElementById(returnId)?.focus()
  }

  keydown(event) {
    if (!this.hasFrameTarget || !this.frameTarget.classList.contains("is-open")) return
    if (event.key === "Escape") {
      this.close(event)
      return
    }
    if (event.key !== "Tab") return

    const focusable = Array.from(this.frameTarget.querySelectorAll(
      "a[href], button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex='-1'])"
    )).filter((element) => element.getClientRects().length > 0)
    if (!focusable.length) return

    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  markOpen(moveFocus) {
    this.frameTarget.classList.add("is-open")
    document.body.classList.add("drawer-open")
    if (moveFocus) this.frameTarget.querySelector("[data-drawer-focus]")?.focus()
  }
}
