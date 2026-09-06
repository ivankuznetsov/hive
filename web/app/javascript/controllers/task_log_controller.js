import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["filter", "search", "entry", "empty"]

  connect() {
    this.frame = this.element.closest("turbo-frame")
    this.onFrameLoad = () => this.restore()
    this.frame?.addEventListener("turbo:frame-load", this.onFrameLoad)
    this.restore()
  }

  disconnect() {
    this.frame?.removeEventListener("turbo:frame-load", this.onFrameLoad)
  }

  restore() {
    if (!this.hasFilterTarget) return
    // Frame properties survive content replacement and Turbo morphs.
    // Search pauses polling through poll's existing operatorBusy guard.
    const state = this.frame?.taskLogViewState || {}
    this.filterTarget.value = state.kind || "all"
    this.searchTarget.value = state.query || ""
    this.apply()
  }

  filter() {
    if (this.frame) this.frame.taskLogViewState = {
      kind: this.filterTarget.value, query: this.searchTarget.value
    }
    this.apply()
  }

  apply() {
    const kind = this.filterTarget.value
    const query = this.searchTarget.value.trim().toLowerCase()
    let visible = 0
    this.entryTargets.forEach((entry) => {
      entry.hidden = (kind !== "all" && entry.dataset.kind !== kind) ||
        !entry.textContent.toLowerCase().includes(query)
      if (!entry.hidden) visible += 1
    })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = visible !== 0
  }
}
