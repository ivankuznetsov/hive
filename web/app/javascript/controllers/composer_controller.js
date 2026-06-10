import { Controller } from "@hotwired/stimulus"

// The new-idea composer: images attach by clipboard paste OR the upload
// button (the TUI's two paths, mirrored). Each image gets a monotonic
// [imageN] placeholder spliced at the caret — the same contract
// Commands::New persists into the task's assets/ dir. The counter never
// decrements on removal so a remove-then-paste cycle can't reuse a label.
export default class extends Controller {
  static targets = ["text", "files", "picker", "chips"]

  connect() {
    this.counter = 0
    this.attachments = new Map()
  }

  paste(event) {
    const items = Array.from(event.clipboardData?.items || [])
    const images = items.filter((item) => item.type.startsWith("image/"))
    if (images.length === 0) return

    event.preventDefault()
    images.forEach((item) => this.add(item.getAsFile()))
  }

  pick() {
    this.pickerTarget.click()
  }

  picked(event) {
    Array.from(event.target.files || []).forEach((file) => {
      if (file.type.startsWith("image/")) this.add(file)
    })
    event.target.value = ""
  }

  add(file) {
    if (!file) return

    this.counter += 1
    const label = `image${this.counter}`
    const ext = (file.name.match(/\.[a-z0-9]{1,5}$/i)?.[0] || extensionFor(file.type)).toLowerCase()
    const named = new File([file], `${label}${ext}`, { type: file.type })
    this.attachments.set(label, named)
    this.insertPlaceholder(`[${label}]`)
    this.renderChip(label, named)
    this.syncInput()
  }

  remove(event) {
    const label = event.params.label
    this.attachments.delete(label)
    this.chipsTarget.querySelector(`[data-chip="${label}"]`)?.remove()
    this.textTarget.value = this.textTarget.value
      .replace(new RegExp(`\\s?\\[${label}\\]`, "g"), "")
    this.syncInput()
  }

  insertPlaceholder(placeholder) {
    const input = this.textTarget
    const start = input.selectionStart ?? input.value.length
    const end = input.selectionEnd ?? start
    const before = input.value.slice(0, start)
    const pad = before === "" || before.endsWith(" ") || before.endsWith("\n") ? "" : " "
    input.value = before + pad + placeholder + input.value.slice(end)
    const caret = start + pad.length + placeholder.length
    input.setSelectionRange(caret, caret)
    input.focus()
  }

  renderChip(label, file) {
    const chip = document.createElement("span")
    chip.className = "chip"
    chip.dataset.chip = label

    const img = document.createElement("img")
    img.alt = ""
    img.src = URL.createObjectURL(file)
    chip.appendChild(img)

    chip.appendChild(document.createTextNode(label))

    const button = document.createElement("button")
    button.type = "button"
    button.textContent = "×"
    button.setAttribute("aria-label", `Remove ${label}`)
    button.dataset.action = "composer#remove"
    button.dataset.composerLabelParam = label
    chip.appendChild(button)

    this.chipsTarget.appendChild(chip)
  }

  // The hidden multi-file input is the transport: DataTransfer rebuilds its
  // FileList so the form submits the staged images as images[].
  syncInput() {
    const transfer = new DataTransfer()
    this.attachments.forEach((file) => transfer.items.add(file))
    this.filesTarget.files = transfer.files
  }
}

function extensionFor(type) {
  const map = { "image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp" }
  return map[type] || ".png"
}
