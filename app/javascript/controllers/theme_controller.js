import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["sun", "moon"]

  connect() {
    this.render()
  }

  toggle() {
    const current = this.currentTheme()
    const next = current === "dark" ? "light" : "dark"
    localStorage.setItem("theme", next)
    this.apply(next)
    this.render()
  }

  currentTheme() {
    return document.documentElement.classList.contains("dark") ? "dark" : "light"
  }

  apply(theme) {
    if (theme === "dark") {
      document.documentElement.classList.add("dark")
    } else {
      document.documentElement.classList.remove("dark")
    }
  }

  render() {
    const dark = this.currentTheme() === "dark"
    if (this.hasSunTarget) this.sunTarget.classList.toggle("hidden", dark)
    if (this.hasMoonTarget) this.moonTarget.classList.toggle("hidden", !dark)
  }
}
