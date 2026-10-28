import { Controller } from "@hotwired/stimulus"
import { copyTaskReference } from "lib/copy_task_reference"
export default class extends Controller {
  copy(event) { return copyTaskReference(event.currentTarget) }
}
