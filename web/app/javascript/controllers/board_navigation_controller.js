import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["card"]

  connect() {
    this.media = window.matchMedia("(max-width: 767px)")
    this.resize = () => this.applyStagePagers()
    this.morph = new MutationObserver(() => this.reconcileTabStops())
    this.media.addEventListener("change", this.resize)
    this.morph.observe(this.element, { childList: true, subtree: true })
    this.resetTabStops()
    this.applyStagePagers()
  }

  disconnect() {
    this.media.removeEventListener("change", this.resize)
    this.morph.disconnect()
  }

  resetTabStops() {
    this.cardTargets.forEach((card, index) => { card.tabIndex = index === 0 ? 0 : -1 })
  }

  reconcileTabStops() {
    const cards = this.cardTargets
    if (cards.length === 0) return

    const focused = document.activeElement?.closest?.(".board-card")
    const current = cards.find((card) => card === focused || card.tabIndex === 0) || cards[0]
    cards.forEach((card) => { card.tabIndex = card === current ? 0 : -1 })
  }

  keydown(event) {
    const card = event.target.closest(".board-card")
    if (!card || !this.element.contains(card)) return

    let destination
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      const cards = Array.from(card.closest(".board-column").querySelectorAll(".board-card"))
      const offset = event.key === "ArrowDown" ? 1 : -1
      destination = cards[(cards.indexOf(card) + offset + cards.length) % cards.length]
    } else if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      destination = this.cardAcrossColumns(card, event.key === "ArrowRight" ? 1 : -1)
    } else if (event.key === "Enter") {
      card.querySelector("a")?.click()
      return
    } else {
      return
    }

    if (destination) {
      event.preventDefault()
      this.focusCard(destination)
    }
  }

  cardAcrossColumns(card, offset) {
    const columns = Array.from(card.closest(".board-band").querySelectorAll(".board-column:not([hidden])"))
    let index = columns.indexOf(card.closest(".board-column")) + offset
    while (index >= 0 && index < columns.length) {
      const destination = columns[index].querySelector(".board-card")
      if (destination) return destination
      index += offset
    }
  }

  focusCard(card) {
    this.cardTargets.forEach((candidate) => { candidate.tabIndex = candidate === card ? 0 : -1 })
    card.focus()
  }

  selectStage(event) {
    const band = event.target.closest(".board-band")
    this.applyBandStage(band, event.target.value)
  }

  applyStagePagers() {
    this.element.querySelectorAll(".board-band").forEach((band) => {
      const select = band.querySelector(".stage-pager select")
      if (select) this.applyBandStage(band, select.value)
    })
  }

  applyBandStage(band, stage) {
    band.querySelectorAll(".board-column").forEach((column) => {
      column.hidden = this.media.matches && column.dataset.stage !== stage
    })
  }
}
