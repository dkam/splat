import { Controller } from "@hotwired/stimulus"

// Copies a string to the clipboard and confirms it in place.
//
// Two shapes, depending on where the confirmation can go:
//   - no targets: the clicked button's own label is swapped for "Copied!" and
//     restored two seconds later. The controller sits on the button.
//   - a `feedback` target: that element's text is swapped instead, leaving the
//     rest of the button (an icon, a long id) alone. Lets the controller sit on
//     a wrapper with the copy button somewhere inside it.
export default class extends Controller {
  static targets = ["feedback"]
  static values = { text: String }

  copy(event) {
    event.preventDefault()

    navigator.clipboard.writeText(this.textValue).then(() => {
      if (this.hasFeedbackTarget) {
        this.#flash(this.feedbackTarget, this.feedbackTarget.dataset.copiedText || "Copied!")
      } else {
        this.#flashButton(event.currentTarget)
      }
    }).catch(err => {
      console.error('Failed to copy:', err)
      alert('Failed to copy to clipboard')
    })
  }

  disconnect() {
    clearTimeout(this.timeout)
  }

  // Swap an element's text for a confirmation, then put it back. Guarded
  // against a second click landing mid-flash and capturing "Copied!" as the
  // text to restore.
  #flash(element, message, onRestore) {
    if (this.timeout) {
      clearTimeout(this.timeout)
    } else {
      this.original = element.textContent
    }

    element.textContent = message
    this.timeout = setTimeout(() => {
      element.textContent = this.original
      this.timeout = null
      if (onRestore) onRestore()
    }, 2000)
  }

  #flashButton(button) {
    if (!this.timeout) {
      button.classList.add("bg-green-600")
      button.classList.remove("bg-blue-600", "hover:bg-blue-700")
    }

    this.#flash(button, "Copied!", () => {
      button.classList.remove("bg-green-600")
      button.classList.add("bg-blue-600", "hover:bg-blue-700")
    })
  }
}
