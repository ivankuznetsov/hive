import { Controller } from "@hotwired/stimulus"

// A task page is refreshed by Turbo morphs while the operator may be reading,
// typing, or expanding evidence. Keep those human-owned interaction choices
// outside the server snapshot, keyed only within this exact task workspace.
const lastMaterialSignature = new Map()

export default class extends Controller {
  static targets = ["announcement", "summary"]
  static values = { key: String, signature: String }

  connect() {
    this.snapshot = this.snapshot.bind(this)
    this.restore = this.restore.bind(this)
    document.addEventListener("turbo:before-render", this.snapshot)
    document.addEventListener("turbo:render", this.restore)
    this.recordMaterialSignature()
  }

  disconnect() {
    document.removeEventListener("turbo:before-render", this.snapshot)
    document.removeEventListener("turbo:render", this.restore)
    if (this.scrollRestoreFrame) cancelAnimationFrame(this.scrollRestoreFrame)
    this.scrollRestoreFrame = null
  }

  signatureValueChanged() {
    if (this.element.isConnected) requestAnimationFrame(() => this.recordMaterialSignature())
  }

  loadDiagnosticLog(event) {
    const details = event.currentTarget
    if (!details.open) return

    const frame = details.querySelector("turbo-frame[data-diagnostic-log-src]")
    if (!frame) return

    frame.src = frame.dataset.diagnosticLogSrc
    delete frame.dataset.diagnosticLogSrc
  }

  snapshot(event) {
    if (event.detail.renderMethod !== "morph") return

    this.disclosures = new Map()
    this.element.querySelectorAll("details[data-workspace-disclosure-key]").forEach((details) => {
      this.disclosures.set(details.dataset.workspaceDisclosureKey, details.open)
    })
    this.scrollPosition = { x: window.scrollX, y: window.scrollY }

    const active = document.activeElement
    if (!active || !this.element.contains(active) || active.matches("textarea")) {
      this.focused = null
      return
    }
    const key = active.id || active.getAttribute("name")
    if (!key) {
      this.focused = null
      return
    }
    this.focused = {
      key,
      byId: Boolean(active.id),
      start: Number.isInteger(active.selectionStart) ? active.selectionStart : null,
      end: Number.isInteger(active.selectionEnd) ? active.selectionEnd : null
    }
  }

  restore(event) {
    if (event.detail.renderMethod !== "morph") return

    if (this.disclosures) {
      this.element.querySelectorAll("details[data-workspace-disclosure-key]").forEach((details) => {
        const open = this.disclosures.get(details.dataset.workspaceDisclosureKey)
        if (open !== undefined) details.open = open
      })
    }

    if (this.focused) {
      const selector = this.focused.byId
        ? `#${CSS.escape(this.focused.key)}`
        : `[name="${CSS.escape(this.focused.key)}"]`
      const target = this.element.querySelector(selector)
      if (target) {
        target.focus({ preventScroll: true })
        if (this.focused.start !== null && typeof target.setSelectionRange === "function") {
          target.setSelectionRange(this.focused.start, this.focused.end)
        }
      }
    }

    const scroll = this.scrollPosition
    if (this.scrollRestoreFrame) cancelAnimationFrame(this.scrollRestoreFrame)
    if (scroll) {
      this.scrollRestoreFrame = requestAnimationFrame(() => {
        this.scrollRestoreFrame = null
        if (this.element.isConnected) window.scrollTo(scroll.x, scroll.y)
      })
    }
    this.disclosures = null
    this.focused = null
    this.scrollPosition = null
    this.recordMaterialSignature()
  }

  recordMaterialSignature() {
    if (!this.hasKeyValue || !this.hasSignatureValue) return

    const previous = lastMaterialSignature.get(this.keyValue)
    lastMaterialSignature.set(this.keyValue, this.signatureValue)
    if (lastMaterialSignature.size > 100) {
      const oldest = lastMaterialSignature.keys().next().value
      lastMaterialSignature.delete(oldest)
    }
    if (!previous || previous === this.signatureValue || !this.hasAnnouncementTarget) return

    const summary = this.hasSummaryTarget ? this.summaryTarget.textContent.trim() : "Task status changed."
    this.announcementTarget.textContent = summary.replace(/\s+/g, " ")
  }
}
