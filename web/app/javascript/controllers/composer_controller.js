import { Controller } from "@hotwired/stimulus"

// The new-idea composer: images attach by clipboard paste OR the upload
// button (the TUI's two paths, mirrored). Each image gets a monotonic
// [imageN] placeholder spliced at the caret — the same contract
// Commands::New persists into the task's assets/ dir. The counter never
// decrements on removal so a remove-then-paste cycle can't reuse a label.
export default class extends Controller {
  static targets = ["text", "files", "picker", "chips"]

  connect() {
    this.attachments = new Map()
    this.previewUrls = new Map()

    // A data-turbo-permanent form can reconnect after Turbo moves it into a
    // morphed document. Rebuild the controller's in-memory index from the
    // preserved transport input so staged files remain removable/submittable.
    this.counter = 0
    Array.from(this.filesTarget.files || []).forEach((file) => {
      const label = file.name.match(/^image\d+/)?.[0]
      if (!label) return

      this.attachments.set(label, file)
      this.counter = Math.max(this.counter, Number(label.slice("image".length)))
    })
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
    this.revokePreview(label)
    this.chipsTarget.querySelector(`[data-chip="${label}"]`)?.remove()
    this.textTarget.value = this.textTarget.value
      .replace(new RegExp(`\\s?\\[${label}\\]`, "g"), "")
    this.syncInput()
  }

  // Turbo keeps this form alive across the successful redirect so live grid
  // updates cannot destroy an unfinished idea. That same permanence must not
  // keep a FINISHED idea around. turbo:before-fetch-response arrives while
  // the permanent node is still connected; turbo:submit-end is the fallback
  // for clients that only expose the completion event. Clear only after a
  // successful response, while retaining the selected project as useful
  // context for the next idea.
  submitted(event) {
    const success = event.detail.success ?? event.detail.fetchResponse?.succeeded
    if (!success) return

    this.attachments.forEach((_file, label) => this.revokePreview(label))
    this.attachments.clear()
    this.chipsTarget.replaceChildren()
    this.textTarget.value = ""
    this.pickerTarget.value = ""
    this.filesTarget.value = ""
    this.counter = 0
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
    this.previewUrls.set(label, img.src)
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

  revokePreview(label) {
    const chipUrl = this.chipsTarget
      .querySelector(`[data-chip="${label}"] img`)
      ?.src
    const url = this.previewUrls.get(label) || chipUrl
    if (url?.startsWith("blob:")) URL.revokeObjectURL(url)
    this.previewUrls.delete(label)
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
