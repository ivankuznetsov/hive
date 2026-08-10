import { Controller } from "@hotwired/stimulus"

const REDIRECT_DESTINATION_ATTRIBUTE = "status-refresh-redirect-destination"
const STATUS_SURFACE_SELECTOR = "[data-controller~='status-refresh']"

// Turbo morphs can disconnect/reconnect the Stimulus controller while a form
// submission is still crossing the document boundary. Keep refresh admission
// at module scope so that short lifecycle gap cannot erase in-flight state.
const inFlightForms = new Set()
let refreshPending = false

function replayStatusRefresh() {
  const stream = document.createElement("turbo-stream")
  stream.setAttribute("action", "refresh")
  document.documentElement.appendChild(stream)
}

function redirectInFlight() {
  const destination = document.documentElement.getAttribute(REDIRECT_DESTINATION_ATTRIBUTE)
  if (!destination) return false

  const current = new URL(window.location.href)
  const target = new URL(destination, current)
  if (current.pathname !== target.pathname || current.search !== target.search) return true

  document.documentElement.removeAttribute(REDIRECT_DESTINATION_ATTRIBUTE)
  return false
}

function sameLocation(left, right) {
  const base = new URL(window.location.href)
  const first = new URL(left, base)
  const second = new URL(right, base)
  return first.pathname === second.pathname && first.search === second.search
}

function submitting(event) {
  if (event.target.closest?.(STATUS_SURFACE_SELECTOR)) inFlightForms.add(event.target)
}

function submitted(event) {
  if (!inFlightForms.delete(event.target)) return
  if (inFlightForms.size > 0) return

  // A successful redirected mutation already reconciles from a fresh GET.
  // Guard its final URL on <html>, which survives Turbo's body/controller swap.
  if (event.detail?.success && event.detail?.fetchResponse?.redirected) {
    refreshPending = false
    const destination = event.detail.fetchResponse.location?.href
    if (destination) {
      document.documentElement.setAttribute(REDIRECT_DESTINATION_ATTRIBUTE, destination)
      if (redirectInFlight()) {
        document.addEventListener("turbo:load", redirectInFlight, { once: true })
      }
    }
    return
  }

  if (!refreshPending) return

  refreshPending = false
  replayStatusRefresh()
}

function beforeStreamRender(event) {
  const stream = event.detail?.newStream || event.target
  if (stream?.getAttribute("action") !== "refresh") return
  if (redirectInFlight()) {
    event.preventDefault()
    return
  }
  if (inFlightForms.size === 0) return

  refreshPending = true
  event.preventDefault()
}

// Turbo turns a refresh stream into a replace visit of the current URL. Stop
// that visit as a second line of defense: the stream may have been accepted
// just before a native submit reached the document, but it must not be allowed
// to win after the mutation redirects somewhere else.
function beforeVisit(event) {
  const guarded = inFlightForms.size > 0 || redirectInFlight()
  if (!guarded || !event.detail?.url) return
  if (!sameLocation(event.detail.url, window.location.href)) return

  if (inFlightForms.size > 0) refreshPending = true
  event.preventDefault()
}

document.addEventListener("turbo:submit-start", submitting)
document.addEventListener("turbo:submit-end", submitted)
document.addEventListener("turbo:before-stream-render", beforeStreamRender)
document.addEventListener("turbo:before-visit", beforeVisit)

// A status refresh has no Turbo request ID because it comes from a background
// filesystem subscriber. Submission admission above prevents it from aborting
// a mutation. StatusChannel owns reconnect freshness through a versioned
// Action Cable handshake, so this controller has no DOM observer or timer.
export default class extends Controller {
  connect() {
    redirectInFlight()
  }
}
