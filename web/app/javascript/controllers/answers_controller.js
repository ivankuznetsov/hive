import { Controller } from "@hotwired/stimulus"

// Carries Q&A and steer textareas across pushed morphs. The forms must NOT
// be data-turbo-permanent: morphing cannot REMOVE permanent elements, so a
// new question round (different form id) would leave the previous round's
// form lingering beside the new one — caught live by a system test. Instead
// the forms morph freely (server HTML renders them empty) and this
// controller restores the operator's typed-but-unsent text and caret after
// each morph, keyed by opaque draft identity. Answer fields carry that identity
// in their names; the free-form intervention field uses data-draft-key while
// retaining name=message for the POST contract. A new round therefore cannot
// restore a draft onto a changed slot even when it reuses the question number.
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
      pendingFocus = { key: this.fieldKey(active), start: active.selectionStart, end: active.selectionEnd }
    }
  }

  restore() {
    this.restoreFields()
  }

  restoreFields() {
    drafts.forEach((value, key) => {
      const field = this.fieldForKey(key)
      if (field && !field.value) field.value = value
    })
    if (pendingFocus) {
      const field = this.fieldForKey(pendingFocus.key)
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
    pendingFocus = { key: this.fieldKey(field), start: field.selectionStart, end: field.selectionEnd }
  }

  trackFocus(event) {
    const field = event.target
    pendingFocus = field.matches("textarea") && this.element.contains(field)
      ? { key: this.fieldKey(field), start: field.selectionStart, end: field.selectionEnd }
      : null
  }

  remember(field) {
    const key = this.fieldKey(field)
    if (!key) return
    if (!field.value) {
      drafts.delete(key)
      return
    }

    drafts.delete(key)
    drafts.set(key, field.value)
    if (drafts.size > 100) drafts.delete(drafts.keys().next().value)
  }

  fieldKey(field) {
    return field.dataset.draftKey || field.name
  }

  fieldForKey(key) {
    return Array.from(this.element.querySelectorAll("textarea"))
      .find((field) => this.fieldKey(field) === key)
  }
}
