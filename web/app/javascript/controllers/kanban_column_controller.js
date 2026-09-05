import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle", "cards"]
  static values = { defaultFolded: Boolean, label: String }

  connect() { this.restore() }
  defaultFoldedValueChanged() { this.restore() }

  restore(event) {
    if (event && event.target !== this.element) return
    if (!this.hasToggleTarget || !this.hasCardsTarget) return
    let choice = null
    try { choice = localStorage.getItem(this.storageKey) } catch { /* Storage can be disabled. */ }
    this.render(choice === null ? this.defaultFoldedValue : choice === "true")
  }

  toggle() {
    const folded = !this.element.classList.contains("is-folded")
    try { localStorage.setItem(this.storageKey, String(folded)) } catch { /* Folding still works. */ }
    this.render(folded)
  }

  render(folded) {
    this.element.classList.toggle("is-folded", folded)
    this.cardsTarget.hidden = folded
    this.toggleTarget.setAttribute("aria-expanded", String(!folded))
    this.toggleTarget.setAttribute("aria-label", `${folded ? "Expand" : "Fold"} ${this.labelValue} column`)
  }

  get storageKey() { return `hive:kanban-fold:${this.element.id}` }
}
