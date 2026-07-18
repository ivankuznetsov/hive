import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  disconnect() {
    clearTimeout(this.searchTimer)
  }

  submit() {
    this.element.requestSubmit()
  }

  search() {
    clearTimeout(this.searchTimer)
    this.searchTimer = setTimeout(() => this.submit(), 250)
  }
}
