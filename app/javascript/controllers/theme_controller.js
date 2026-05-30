import { Controller } from "@hotwired/stimulus"

const ORDER = ["light", "dark", "auto"]

export default class extends Controller {
  static targets = ["sun", "moon", "auto"]

  connect() {
    this.media = window.matchMedia("(prefers-color-scheme: dark)")
    this.mediaListener = () => { if (this.mode() === "auto") this.applyEffective() }
    this.media.addEventListener("change", this.mediaListener)
    this.render()
  }

  disconnect() {
    if (this.media && this.mediaListener) {
      this.media.removeEventListener("change", this.mediaListener)
    }
  }

  toggle() {
    const idx = ORDER.indexOf(this.mode())
    const next = ORDER[(idx + 1) % ORDER.length]
    if (next === "auto") {
      localStorage.removeItem("theme")
    } else {
      localStorage.setItem("theme", next)
    }
    this.applyEffective()
    this.render()
  }

  mode() {
    const stored = localStorage.getItem("theme")
    return stored === "dark" || stored === "light" ? stored : "auto"
  }

  effective() {
    const m = this.mode()
    return m === "auto" ? (this.media.matches ? "dark" : "light") : m
  }

  applyEffective() {
    document.documentElement.classList.toggle("dark", this.effective() === "dark")
  }

  render() {
    const m = this.mode()
    if (this.hasSunTarget) this.sunTarget.classList.toggle("hidden", m !== "light")
    if (this.hasMoonTarget) this.moonTarget.classList.toggle("hidden", m !== "dark")
    if (this.hasAutoTarget) this.autoTarget.classList.toggle("hidden", m !== "auto")
  }
}
