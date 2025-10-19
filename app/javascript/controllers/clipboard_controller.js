import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { text: String }

  copy(event) {
    event.preventDefault()

    navigator.clipboard.writeText(this.textValue).then(() => {
      const button = event.currentTarget
      const originalText = button.textContent

      button.textContent = "Copied!"
      button.classList.add("bg-green-600")
      button.classList.remove("bg-blue-600", "hover:bg-blue-700")

      setTimeout(() => {
        button.textContent = originalText
        button.classList.remove("bg-green-600")
        button.classList.add("bg-blue-600", "hover:bg-blue-700")
      }, 2000)
    }).catch(err => {
      console.error('Failed to copy:', err)
      alert('Failed to copy to clipboard')
    })
  }
}
