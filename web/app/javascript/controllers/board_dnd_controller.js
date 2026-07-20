import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.desktop = window.matchMedia("(min-width: 768px) and (pointer: fine)")
    this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.refresh = () => this.syncCards()
    this.desktop.addEventListener("change", this.refresh)
    this.reducedMotion.addEventListener("change", this.refresh)
    this.observer = new MutationObserver(this.refresh)
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.pending = new WeakMap()
    this.syncCards()
  }

  disconnect() {
    this.desktop.removeEventListener("change", this.refresh)
    this.reducedMotion.removeEventListener("change", this.refresh)
    this.observer.disconnect()
  }

  syncCards() {
    const enabled = this.desktop.matches && !this.reducedMotion.matches
    this.element.querySelectorAll(".board-card").forEach((card) => {
      card.draggable = enabled && this.transitions(card).length > 0 && card.dataset.transitionPending !== "true"
    })
  }

  start(event) {
    const card = event.target.closest(".board-card")
    if (!card?.draggable || event.target.closest("a, button, input, summary")) {
      event.preventDefault()
      return
    }

    const band = card.closest(".board-band")
    this.drag = {
      card,
      band,
      destinations: this.transitions(card).map((transition) => transition.destination),
      parent: card.parentNode,
      next: card.nextSibling,
      sourceColumn: card.closest(".board-column")
    }
    card.classList.add("is-dragging")
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", card.dataset.cardSlug)
    this.columns(band).forEach((column) => {
      column.classList.toggle("drop-allowed", this.drag.destinations.includes(column.dataset.stage))
    })
  }

  over(event) {
    const column = event.target.closest(".board-column")
    if (!this.allowed(column)) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    column.classList.add("is-drop-target")
  }

  leave(event) {
    const column = event.target.closest(".board-column")
    if (column && !column.contains(event.relatedTarget)) column.classList.remove("is-drop-target")
  }

  drop(event) {
    const column = event.target.closest(".board-column")
    if (!this.allowed(column)) return

    event.preventDefault()
    const destination = column.dataset.stage
    const settlement = this.drag
    column.querySelector(".board-column-cards")?.append(settlement.card)
    settlement.card.classList.remove("is-dragging")
    settlement.card.classList.add("is-transition-pending")
    this.pending.set(settlement.card, settlement)
    settlement.card.dispatchEvent(new CustomEvent("board:transition-request", {
      bubbles: false, detail: { destination, source: "drag" }
    }))
    this.clearColumns(settlement.band)
    this.drag = null
  }

  finish() {
    this.drag?.card.classList.remove("is-dragging")
    this.clearColumns(this.drag?.band)
    this.drag = null
  }

  settled(event) {
    const card = event.target.closest(".board-card")
    if (card) this.pending.delete(card)
  }

  failed(event) {
    const failedCard = event.target.closest(".board-card")
    const settlement = failedCard && this.pending.get(failedCard)
    if (event.detail.card) {
      failedCard?.classList.remove("is-dragging", "is-transition-pending")
      if (settlement) {
        this.clearColumns(settlement.band)
        this.pending.delete(failedCard)
      }
      this.element.dispatchEvent(new CustomEvent("board:reconcile-request", {
        bubbles: true, detail: { message: "Task changed; refreshing current state" }
      }))
      return
    }
    if (event.detail.source !== "drag" || !settlement) return

    const { card, parent, next, band } = settlement
    next?.parentNode === parent ? parent.insertBefore(card, next) : parent.append(card)
    card.classList.remove("is-dragging", "is-transition-pending")
    this.clearColumns(band)
    this.pending.delete(card)
  }

  allowed(column) {
    return this.drag && column && column.closest(".board-band") === this.drag.band &&
      this.drag.destinations.includes(column.dataset.stage)
  }

  columns(band = this.drag?.band) {
    return band ? Array.from(band.querySelectorAll(".board-column")) : []
  }

  clearColumns(band) {
    this.columns(band).forEach((column) => column.classList.remove("drop-allowed", "is-drop-target"))
  }

  transitions(card) {
    try {
      return JSON.parse(card.dataset.boardDndTransitions || "[]")
    } catch (_error) {
      return []
    }
  }
}
