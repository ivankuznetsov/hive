import { Controller } from "@hotwired/stimulus"

// Renders an agent-written Mermaid diagram in the daily digest. The source is
// untrusted: Mermaid runs in strict mode with HTML labels off, so labels are
// SVG text, and any image, link, or foreignObject node is dropped before the
// SVG reaches the page. The bundle (~2.5 MB) is a classic script that defines
// globalThis.mermaid, so it is injected once, only on pages with a diagram.
// The escaped source stays visible when anything fails.
let sequence = 0
let loading

function loadMermaid(src) {
  loading ||= new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = src
    script.onload = resolve
    script.onerror = () => {
      loading = undefined
      reject(new Error("mermaid failed to load"))
    }
    document.head.append(script)
  }).then(() => {
    const dark = window.matchMedia("(prefers-color-scheme: dark)").matches
    globalThis.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      htmlLabels: false,
      flowchart: { htmlLabels: false },
      theme: dark ? "dark" : "neutral",
      fontFamily: "inherit"
    })
    return globalThis.mermaid
  })
  return loading
}

export default class extends Controller {
  static targets = [ "source" ]
  static values = { src: String }

  async connect() {
    try {
      const mermaid = await loadMermaid(this.srcValue)
      const { svg } = await mermaid.render(`digest-diagram-${++sequence}`, this.sourceTarget.textContent)
      const rendered = document.createElement("div")
      rendered.className = "digest-diagram-rendered"
      rendered.innerHTML = svg
      rendered.querySelectorAll("img, image, foreignObject, a").forEach((node) => node.remove())
      this.element.prepend(rendered)
      this.sourceTarget.hidden = true
      this.element.dataset.diagramState = "rendered"
    } catch (error) {
      this.element.dataset.diagramState = "failed"
    }
  }
}
