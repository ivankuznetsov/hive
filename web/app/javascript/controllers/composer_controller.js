import { Controller } from "@hotwired/stimulus"

const MAX_BATCH_INSPECTIONS = 16

// The new-idea composer: images attach by clipboard paste OR the upload
// button (the TUI's two paths, mirrored). Each image gets a monotonic
// [imageN] placeholder spliced at the caret — the same contract
// Commands::New persists into the task's assets/ dir. The counter never
// decrements on removal so a remove-then-paste cycle can't reuse a label.
export default class extends Controller {
  static targets = ["text", "files", "picker", "chips", "feedback"]
  static values = {
    maxFiles: { type: Number, default: 8 },
    maxFileBytes: { type: Number, default: 10 * 1024 * 1024 }
  }

  connect() {
    clearTimeout(this.attachmentCleanupTimer)
    this.attachments = new Map()

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

  disconnect() {
    // Turbo temporarily disconnects data-turbo-permanent nodes while moving
    // them into the new document. Give that move a short cancellable window;
    // a genuinely abandoned composer then releases its browser-owned FileList.
    clearTimeout(this.attachmentCleanupTimer)
    this.attachmentCleanupTimer = setTimeout(() => {
      if (this.element.isConnected) return

      this.attachments.clear()
      this.pickerTarget.value = ""
      this.filesTarget.value = ""
    }, 100)
  }

  paste(event) {
    const handled = this.addFiles(event.clipboardData?.items)
    if (!handled) return

    event.preventDefault()
  }

  pick() {
    this.pickerTarget.click()
  }

  picked(event) {
    this.addFiles(event.target.files)
    event.target.value = ""
  }

  addFiles(files) {
    const accepted = []
    let oversized = 0
    let overflow = 0
    let imageCandidates = 0
    const sourceLength = Math.max(0, Number(files?.length) || 0)
    const inspectedLength = Math.min(sourceLength, MAX_BATCH_INSPECTIONS)

    for (let index = 0; index < inspectedLength; index += 1) {
      const candidate = files[index]
      const file = typeof candidate?.getAsFile === "function" ? candidate.getAsFile() : candidate
      if (!file?.type?.startsWith("image/")) continue

      imageCandidates += 1
      if (file.size > this.maxFileBytesValue) {
        oversized += 1
      } else if (this.attachments.size + accepted.length >= this.maxFilesValue) {
        overflow += 1
      } else {
        accepted.push(file)
      }
    }

    accepted.forEach((file) => this.stage(file))
    if (accepted.length > 0) this.syncInput()
    this.reportRejected({ oversized, overflow, truncated: sourceLength > inspectedLength })
    return imageCandidates > 0
  }

  stage(file) {
    this.counter += 1
    const label = `image${this.counter}`
    const ext = (file.name.match(/\.[a-z0-9]{1,5}$/i)?.[0] || extensionFor(file.type)).toLowerCase()
    const named = new File([file], `${label}${ext}`, { type: file.type })
    this.attachments.set(label, named)
    this.insertPlaceholder(`[${label}]`)
    this.renderChip(label)
  }

  remove(event) {
    const label = event.params.label
    this.attachments.delete(label)
    this.chipsTarget.querySelector(`[data-chip="${label}"]`)?.remove()
    this.textTarget.value = this.textTarget.value
      .replace(new RegExp(`\\s?\\[${label}\\]`, "g"), "")
    this.syncInput()
    this.clearFeedback()
  }

  // Preserve the browser-owned project selection when the broadcaster updates
  // the composer options. Submission/refresh ordering belongs to the parent
  // status-refresh controller because task-action forms need the same guard.
  beforeStreamRender(event) {
    const stream = event.detail?.newStream || event.target
    // The server owns the live project order, but the selected project is
    // unfinished form state owned by this browser. Preserve that choice when
    // Turbo morphs the select, provided the project still exists.
    if (stream?.getAttribute("target") !== "composer-project") return

    const selectedProject = this.element.querySelector("#composer-project")?.value
    if (!selectedProject) return

    const render = event.detail.render
    event.detail.render = async (newStream) => {
      await render(newStream)

      const select = this.element.querySelector("#composer-project")
      const projectStillExists = Array.from(select?.options || [])
        .some((option) => option.value === selectedProject)
      if (projectStillExists) select.value = selectedProject
    }
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

    this.attachments.clear()
    this.chipsTarget.replaceChildren()
    this.textTarget.value = ""
    this.pickerTarget.value = ""
    this.filesTarget.value = ""
    this.counter = 0
    this.clearFeedback()
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

  renderChip(label) {
    const chip = document.createElement("span")
    chip.className = "chip"
    chip.dataset.chip = label

    // Do not decode selected images on the status page. Compressed files can
    // have enormous pixel dimensions despite passing the byte limit; a generic
    // chip keeps decoded-memory use constant until the server stores the file.
    const icon = document.createElement("span")
    icon.className = "chip-icon"
    icon.setAttribute("aria-hidden", "true")
    icon.textContent = "▧"
    chip.appendChild(icon)

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

  reportRejected({ oversized, overflow, truncated }) {
    const messages = []
    if (oversized > 0) {
      const verb = oversized === 1 ? "was" : "were"
      messages.push(
        `${pluralize(oversized, "image")} exceeded the ${formatBytes(this.maxFileBytesValue)} limit and ${verb} not added.`
      )
    }
    if (overflow > 0) {
      messages.push(`Only ${this.maxFilesValue} images can be attached; ${pluralize(overflow, "image")} not added.`)
    }
    if (truncated) messages.push("Additional files were not inspected or added.")

    this.feedbackTarget.textContent = messages.join(" ")
  }

  clearFeedback() {
    this.feedbackTarget.textContent = ""
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

function pluralize(count, noun) {
  return `${count} ${noun}${count === 1 ? "" : "s"}`
}

function formatBytes(bytes) {
  const mebibytes = bytes / (1024 * 1024)
  return `${Number.isInteger(mebibytes) ? mebibytes : mebibytes.toFixed(1)} MB`
}
