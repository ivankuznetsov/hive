import { Controller } from "@hotwired/stimulus"

// TUI left-pane parity: filter the status grid to one project (or all).
// Pure client state — the grid keeps receiving full broadcasts and morphs,
// and a MutationObserver re-applies the filter after each one (the
// broadcast REPLACES #projects, dropping any hidden attributes we set).
// The choice is mirrored into the URL (?project=) so a reload or shared
// link lands filtered, without a navigation that would discard the
// permanent composer's typed text.
export default class extends Controller {
  static targets = ["button"]

  connect() {
    this.selected = new URLSearchParams(window.location.search).get("project") || ""
    // childList only: apply() toggles attributes, which must not retrigger.
    this.observer = new MutationObserver(() => this.apply())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.apply()
    // A filtered deep-link also preselects the composer — but never over a
    // value that is already chosen (e.g. the single-project preselect).
    this.syncComposer(true)
  }

  disconnect() {
    this.observer.disconnect()
  }

  choose(event) {
    this.selected = event.params.name || ""
    const url = new URL(window.location)
    if (this.selected) url.searchParams.set("project", this.selected)
    else url.searchParams.delete("project")
    history.replaceState({}, "", url)
    this.apply()
    // Filtering IS a project context switch — new ideas should land there.
    // Only on the explicit click: apply() also runs on every broadcast, and
    // re-syncing there would clobber a manual select change mid-compose.
    this.syncComposer()
  }

  syncComposer(onlyIfUnset = false) {
    if (!this.selected) return

    const select = this.element.querySelector("#composer select[name='project']")
    if (!select) return
    if (onlyIfUnset && select.value) return

    if (Array.from(select.options).some((option) => option.value === this.selected)) {
      select.value = this.selected
    }
  }

  apply() {
    this.element.querySelectorAll("[data-project-name]").forEach((section) => {
      const show = !this.selected || section.dataset.projectName === this.selected
      if (section.hidden === show) section.hidden = !show
    })
    this.buttonTargets.forEach((button) => {
      button.classList.toggle("active", (button.dataset.projectFilterNameParam || "") === this.selected)
    })
  }
}
