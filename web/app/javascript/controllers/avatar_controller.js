import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    if (this.element.complete && this.element.naturalWidth === 0) this.hide()
  }

  hide() {
    this.element.hidden = true
  }
}
