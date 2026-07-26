import { Controller } from "@hotwired/stimulus"

// Breathing room between the tooltip and the viewport edge.
const MARGIN = 4

// Instant tooltips for the hover columns rendered by ApplicationHelper#sparkline
// (`bar_titles:`). The server ships each column with a native <title> so the
// chart still explains itself with JS off; on connect we lift those labels into
// data attributes and drop the <title> nodes, trading the browser's ~1s tooltip
// delay for one that tracks the cursor — you can drag along a 168-bucket chart
// and read every value.
//
// Usage: put data-controller="sparkline-tooltip" on the element wrapping the
// <svg>. Positioning is relative to that element.
export default class extends Controller {
  connect() {
    this.columns = Array.from(this.element.querySelectorAll("rect.sparkline-hover"))
    if (this.columns.length === 0) return

    this.columns.forEach((column) => {
      const title = column.querySelector("title")
      if (!title) return
      column.dataset.sparklineLabel = title.textContent
      title.remove()
    })

    // Fixed, not absolute: half these charts live in table cells inside an
    // overflow-hidden card, which would clip an absolutely positioned tooltip.
    this.tooltip = document.createElement("div")
    this.tooltip.className =
      "pointer-events-none fixed z-50 hidden whitespace-nowrap rounded-md bg-gray-900 dark:bg-gray-700 " +
      "px-2 py-1 text-xs font-medium text-white shadow-lg"
    this.element.appendChild(this.tooltip)

    this.element.addEventListener("pointermove", this.move)
    this.element.addEventListener("pointerleave", this.hide)
    // A fixed-position tooltip doesn't travel with the page; drop it instead of
    // leaving it stranded mid-scroll.
    window.addEventListener("scroll", this.hide, {passive: true})
  }

  disconnect() {
    this.element.removeEventListener("pointermove", this.move)
    this.element.removeEventListener("pointerleave", this.hide)
    window.removeEventListener("scroll", this.hide)
    this.tooltip?.remove()
    this.tooltip = null
  }

  move = (event) => {
    if (!this.tooltip) return

    const column = event.target.closest?.("rect.sparkline-hover")
    const label = column?.dataset?.sparklineLabel
    if (!label) return this.hide()

    if (this.tooltip.textContent !== label) this.tooltip.textContent = label
    this.tooltip.classList.remove("hidden")

    // Centre on the cursor, clamped to the viewport so it can't run off the
    // edge on the first or last bucket of a chart near the window's margin.
    const bounds = this.element.getBoundingClientRect()
    const width = this.tooltip.offsetWidth
    const height = this.tooltip.offsetHeight
    const left = Math.min(
      Math.max(event.clientX - width / 2, MARGIN),
      Math.max(window.innerWidth - width - MARGIN, MARGIN)
    )

    // Pinned just above the chart rather than to the cursor: these charts are
    // 24–80px tall, so a cursor-anchored box covers the bars you're reading,
    // and a fixed height means no vertical jitter while you drag along the
    // series. Only when the chart is near the top of the viewport does it
    // drop below.
    const above = bounds.top - height - 8
    const top = above >= MARGIN ? above : bounds.bottom + 8

    this.tooltip.style.left = `${Math.round(left)}px`
    this.tooltip.style.top = `${Math.round(top)}px`
  }

  hide = () => {
    this.tooltip?.classList.add("hidden")
  }
}
