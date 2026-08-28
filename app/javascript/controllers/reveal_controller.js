import { Controller } from "@hotwired/stimulus"

// Swaps a masked placeholder for the secret it stands in for, and back. The
// real value is already in the DOM — this is about not putting a token on
// screen unasked, not about keeping it from the reader.
export default class extends Controller {
  static targets = ["masked", "plain", "label"]
  static values = {
    showLabel: { type: String, default: "Show token" },
    hideLabel: { type: String, default: "Hide token" }
  }

  toggle() {
    const revealing = this.plainTarget.classList.contains("hidden")

    this.plainTarget.classList.toggle("hidden", !revealing)
    this.maskedTarget.classList.toggle("hidden", revealing)

    if (this.hasLabelTarget) {
      this.labelTarget.textContent = revealing ? this.hideLabelValue : this.showLabelValue
    }
  }
}
