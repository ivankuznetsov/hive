import { Controller } from "@hotwired/stimulus"

// Page refreshes arrive as Turbo 8 morphs (pushed by StatusBroadcaster).
// Morphing syncs attributes back to the server-rendered HTML, which only
// marks the FIRST artifact open — so a morph would close whatever the
// operator expanded mid-read (and re-open what they closed). Snapshot each
// artifact's open state before a morph and reapply it after, keyed by
// artifact name; names that disappear from the new render simply fall back
// to the fresh server state. Content itself still morphs — artifacts keep
// updating while an agent writes them, only the open/closed choice is the
// operator's.
export default class extends Controller {
  connect() {
    this.snapshot = this.snapshot.bind(this)
    this.restore = this.restore.bind(this)
    document.addEventListener("turbo:before-render", this.snapshot)
    document.addEventListener("turbo:render", this.restore)
  }

  disconnect() {
    document.removeEventListener("turbo:before-render", this.snapshot)
    document.removeEventListener("turbo:render", this.restore)
  }

  // Morphs only: on a real navigation the next page's artifacts must use
  // their own server-rendered state (every task has a brainstorm.md — open
  // states must not leak between task pages).
  snapshot(event) {
    if (event.detail.renderMethod !== "morph") return

    this.openByName = {}
    this.element.querySelectorAll("details[data-artifact-name]").forEach((details) => {
      this.openByName[details.dataset.artifactName] = details.open
    })
  }

  restore(event) {
    if (!this.openByName || event.detail.renderMethod !== "morph") return

    this.element.querySelectorAll("details[data-artifact-name]").forEach((details) => {
      const open = this.openByName[details.dataset.artifactName]
      if (open !== undefined) details.open = open
    })
    this.openByName = null
  }
}
