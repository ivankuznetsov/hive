import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Turbo preserves the composer node across history visits. Keep that useful
// draft preservation, but realign its project after Back/Forward restores a
// filtered URL; otherwise the visible project and submission target diverge.
let historyProject = null

window.addEventListener("popstate", () => {
  historyProject = new URL(window.location.href).searchParams.get("project")
  realignHistoryProject()
})

// A history render can restore the permanent composer after popstate has fired.
// Reapply the URL-owned project once Turbo has finished replacing the page.
document.addEventListener("turbo:render", realignHistoryProject)
document.addEventListener("turbo:before-visit", () => {
  historyProject = null
})
document.addEventListener("turbo:load", () => {
  realignHistoryProject()
  historyProject = null
})

// Project filtering is an ordinary GET rendered by Rails. This one small
// enhancement carries an explicit project choice into the permanent composer
// before Turbo visits the link; unfinished text and staged files stay put.
export default class extends Controller {
  chooseFromSelect(event) {
    const select = event.currentTarget
    if (select.value) selectComposerProject(select.value)
    Turbo.visit(select.selectedOptions[0].dataset.url)
  }

  choose(event) {
    if (event.defaultPrevented || event.button !== 0 ||
        event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    const link = event.currentTarget
    if (link.target && link.target !== "_self") return

    // Stimulus action params JSON-decode values such as "123" and "false".
    // Project names are identifiers, so read the raw attribute string.
    const selected = link.dataset.projectFilterNameParam || ""
    if (!selected) return

    selectComposerProject(selected)
  }
}

function selectComposerProject(selected) {
  const select = document.querySelector("#composer select[name='project']")
  if (Array.from(select?.options || []).some((option) => option.value === selected)) {
    select.value = selected
  }
}

function realignHistoryProject() {
  if (historyProject) selectComposerProject(historyProject)
}
