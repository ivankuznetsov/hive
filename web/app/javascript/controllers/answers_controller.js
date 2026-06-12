import { Controller } from "@hotwired/stimulus"

// Carries Q&A and steer textareas across pushed morphs. The forms must NOT
// be data-turbo-permanent: morphing cannot REMOVE permanent elements, so a
// new question round (different form id) would leave the previous round's
// form lingering beside the new one — caught live by a system test. Instead
// the forms morph freely (server HTML renders them empty) and this
// controller restores the operator's typed-but-unsent text and caret after
// each morph, keyed by field NAME. A new round renders different names
// (answers[2] vs answers[1]), so nothing restores onto it: stale drafts die
// with their round, by construction rather than by timing.
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

  snapshot(event) {
    if (event.detail.renderMethod !== "morph") return

    this.values = {}
    this.element.querySelectorAll("textarea").forEach((field) => {
      if (field.value) this.values[field.name] = field.value
    })
    const active = document.activeElement
    this.focus = active && this.element.contains(active) && active.matches("textarea")
      ? { name: active.name, start: active.selectionStart, end: active.selectionEnd }
      : null
  }

  restore(event) {
    if (!this.values || event.detail.renderMethod !== "morph") return

    Object.entries(this.values).forEach(([name, value]) => {
      const field = this.element.querySelector(`textarea[name="${CSS.escape(name)}"]`)
      if (field && !field.value) field.value = value
    })
    if (this.focus) {
      const field = this.element.querySelector(`textarea[name="${CSS.escape(this.focus.name)}"]`)
      if (field) {
        field.focus()
        field.setSelectionRange(this.focus.start, this.focus.end)
      }
    }
    this.values = null
    this.focus = null
  }
}
