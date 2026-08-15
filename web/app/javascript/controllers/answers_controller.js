import { Controller } from "@hotwired/stimulus"

// Carries Q&A and steer textareas across pushed morphs. The forms must NOT
// be data-turbo-permanent: morphing cannot REMOVE permanent elements, so a
// new question round (different form id) would leave the previous round's
// form lingering beside the new one — caught live by a system test. Instead
// the forms morph freely (server HTML renders them empty) and this
// controller restores the operator's typed-but-unsent text and caret after
// each morph, keyed by field NAME. A new round renders different names
// (each field carries its opaque identity binding), so nothing restores onto
// a changed slot even when a later round reuses the same question number. Old
// bindings remain bounded and cannot restore into a different round.
const drafts = new Map()
let pendingFocus = null

export default class extends Controller {
  connect() {
    this.snapshot = this.snapshot.bind(this)
    this.restore = this.restore.bind(this)
    this.trackFocus = this.trackFocus.bind(this)
    document.addEventListener("turbo:before-render", this.snapshot)
    document.addEventListener("turbo:render", this.restore)
    document.addEventListener("focusin", this.trackFocus)
    this.restoreFields()
  }

  disconnect() {
    document.removeEventListener("turbo:before-render", this.snapshot)
    document.removeEventListener("turbo:render", this.restore)
    document.removeEventListener("focusin", this.trackFocus)
  }

  snapshot() {
    this.element.querySelectorAll("textarea").forEach((field) => {
      if (field.value) this.remember(field)
    })
    const active = document.activeElement
    if (active && this.element.contains(active) && active.matches("textarea")) {
      pendingFocus = { name: active.name, start: active.selectionStart, end: active.selectionEnd }
    }
  }

  restore() {
    this.restoreFields()
  }

  restoreFields() {
    drafts.forEach((value, name) => {
      const field = this.element.querySelector(`textarea[name="${CSS.escape(name)}"]`)
      if (field && !field.value) field.value = value
    })
    if (pendingFocus) {
      const field = this.element.querySelector(`textarea[name="${CSS.escape(pendingFocus.name)}"]`)
      if (field) {
        field.focus()
        field.setSelectionRange(pendingFocus.start, pendingFocus.end)
      }
    }
  }

  recordField(event) {
    const field = event.target
    if (!field.matches("textarea") || !this.element.contains(field)) return

    this.remember(field)
    pendingFocus = { name: field.name, start: field.selectionStart, end: field.selectionEnd }
  }

  trackFocus(event) {
    const field = event.target
    pendingFocus = field.matches("textarea") && this.element.contains(field)
      ? { name: field.name, start: field.selectionStart, end: field.selectionEnd }
      : null
  }

  remember(field) {
    if (!field.name) return
    if (!field.value) {
      drafts.delete(field.name)
      return
    }

    drafts.delete(field.name)
    drafts.set(field.name, field.value)
    if (drafts.size > 100) drafts.delete(drafts.keys().next().value)
  }
}
