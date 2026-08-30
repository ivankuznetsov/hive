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
const suggestionStates = new Map()
const suggestionDrafts = new Map()
let pendingFocus = null
const MAX_SAVED_STATES = 100

export default class extends Controller {
  connect() {
    this.snapshot = this.snapshot.bind(this)
    this.restore = this.restore.bind(this)
    this.trackFocus = this.trackFocus.bind(this)
    document.addEventListener("turbo:before-render", this.snapshot)
    document.addEventListener("turbo:render", this.restore)
    document.addEventListener("focusin", this.trackFocus)
    this.restoreFields()
    this.restoreSuggestions()
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
    this.restoreSuggestions()
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

  approveSuggestion(event) {
    const card = event.currentTarget.closest("[data-suggestion-key]")
    const field = this.answerField(card)
    if (!card || !field || !card.dataset.suggestionText) return

    const state = this.suggestionState(card)
    const draftKey = this.suggestionDraftKey(card, field)
    if (!state.approved && !suggestionDrafts.has(draftKey)) {
      this.rememberSuggestionDraft(draftKey, field.value)
    }
    field.value = card.dataset.suggestionText
    field.dispatchEvent(new Event("input", { bubbles: true }))
    state.approved = true
    state.declined = false
    this.rememberSuggestion(card, state)
    this.renderSuggestion(card, state)
    field.focus()
  }

  undoSuggestion(event) {
    const card = event.currentTarget.closest("[data-suggestion-key]")
    const field = this.answerField(card)
    if (!card || !field) return

    const state = this.suggestionState(card)
    const draftKey = this.suggestionDraftKey(card, field)
    field.value = suggestionDrafts.get(draftKey) || ""
    field.dispatchEvent(new Event("input", { bubbles: true }))
    state.approved = false
    suggestionDrafts.delete(draftKey)
    this.rememberSuggestion(card, state)
    this.renderSuggestion(card, state)
    field.focus()
  }

  declineSuggestion(event) {
    const card = event.currentTarget.closest("[data-suggestion-key]")
    if (!card) return

    const state = this.suggestionState(card)
    state.declined = true
    this.rememberSuggestion(card, state)
    this.renderSuggestion(card, state)
  }

  restoreSuggestion(event) {
    const card = event.currentTarget.closest("[data-suggestion-key]")
    if (!card) return

    const state = this.suggestionState(card)
    state.declined = false
    this.rememberSuggestion(card, state)
    this.renderSuggestion(card, state)
  }

  submitSuggestionRetry(event) {
    const control = event.currentTarget
    if (control.dataset.pending === "true") {
      event.preventDefault()
      return
    }

    control.dataset.pending = "true"
    control.setAttribute("aria-disabled", "true")
    control.setAttribute("aria-busy", "true")
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

  restoreSuggestions() {
    this.element.querySelectorAll("[data-suggestion-key]").forEach((card) => {
      this.renderSuggestion(card, this.suggestionState(card))
    })
  }

  suggestionState(card) {
    const saved = suggestionStates.get(card.dataset.suggestionKey)
    return saved || {
      approved: false,
      declined: card.dataset.suggestionInitialDeclined === "true"
    }
  }

  rememberSuggestion(card, state) {
    const key = card.dataset.suggestionKey
    if (!key) return

    suggestionStates.delete(key)
    suggestionStates.set(key, state)
    if (suggestionStates.size > MAX_SAVED_STATES) {
      suggestionStates.delete(suggestionStates.keys().next().value)
    }
  }

  suggestionDraftKey(card, field) {
    return `${card.dataset.suggestionKey}:${this.fieldKey(field)}`
  }

  rememberSuggestionDraft(key, value) {
    suggestionDrafts.delete(key)
    suggestionDrafts.set(key, value)
    if (suggestionDrafts.size > MAX_SAVED_STATES) {
      suggestionDrafts.delete(suggestionDrafts.keys().next().value)
    }
  }

  renderSuggestion(card, state) {
    const toggle = (part, hidden) => {
      card.querySelectorAll(`[data-suggestion-part='${part}']`).forEach((node) => {
        node.hidden = hidden
      })
    }
    toggle("candidate", state.declined)
    toggle("declined", !state.declined)
    toggle("approve", state.declined || state.approved)
    toggle("undo", state.declined || !state.approved)
    toggle("decline", state.declined || state.approved)
    toggle("restore", !state.declined)
    toggle("approved", state.declined || !state.approved)
  }

  answerField(card) {
    return card?.closest(".qa-item")?.querySelector("textarea[name^='answers[']")
  }
}
