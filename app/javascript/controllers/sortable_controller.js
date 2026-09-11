import { Controller } from "@hotwired/stimulus"

// Drag-to-reorder for the project cards on the index. Native HTML5 drag and
// drop, no library — a grid of a dozen cards doesn't need one, and this app
// has no bundler to vendor one into.
//
// Cards are links, so they're draggable by default in a way that fights us
// (the browser drags the URL). The grip handle is the switch: `draggable` goes
// on the card only while the pointer is down on its handle, which leaves
// click-to-open working everywhere else on the card.
//
// The handle is a real <button>, so the same reordering is available from the
// keyboard with the arrow keys — dragging is not the only way in.
export default class extends Controller {
  static targets = ["item"]
  static values = { url: String }

  // ---- Pointer path ----

  // Arming happens on pointerdown rather than in connect() so a plain click on
  // the card never starts a drag.
  arm(event) {
    const item = this.#itemFor(event.target)
    if (item) item.draggable = true
  }

  disarm(event) {
    const item = this.#itemFor(event.target)
    if (item) item.draggable = false
  }

  start(event) {
    this.dragging = this.#itemFor(event.target)
    if (!this.dragging) return

    this.orderBefore = this.#slugs()
    event.dataTransfer.effectAllowed = "move"
    // Firefox ignores dragstart entirely unless some data is set.
    event.dataTransfer.setData("text/plain", this.dragging.dataset.slug || "")
    // Deferred: applying the class synchronously would have the browser snapshot
    // the half-transparent card as the drag image.
    requestAnimationFrame(() => this.dragging?.classList.add("opacity-40"))
  }

  over(event) {
    if (!this.dragging) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"

    const target = this.#itemFor(event.target)
    if (!target || target === this.dragging) return

    // Compare against the midpoint of the card being hovered so the insertion
    // point flips once, at the centre, rather than jittering at the edges.
    const box = target.getBoundingClientRect()
    const after = (event.clientX - box.left) > box.width / 2
    target.parentNode.insertBefore(this.dragging, after ? target.nextSibling : target)
  }

  drop(event) {
    if (this.dragging) event.preventDefault()
  }

  end() {
    if (!this.dragging) return
    this.dragging.classList.remove("opacity-40")
    this.dragging.draggable = false
    this.dragging = null
    this.#persist()
  }

  // ---- Keyboard path ----

  move(event) {
    const step = { ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 }[event.key]
    if (!step) return

    const item = this.#itemFor(event.target)
    const items = this.itemTargets
    const to = items.indexOf(item) + step
    if (!item || to < 0 || to >= items.length) return

    event.preventDefault()
    this.orderBefore = this.#slugs()
    const neighbour = items[to]
    neighbour.parentNode.insertBefore(item, step > 0 ? neighbour.nextSibling : neighbour)
    // Moving the element detaches focus from it in some browsers.
    event.target.focus()
    this.#persist()
  }

  // ---- Persistence ----

  async #persist() {
    const slugs = this.#slugs()
    if (this.orderBefore && slugs.join() === this.orderBefore.join()) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token || "" },
        body: JSON.stringify({ slugs })
      })
      if (!response.ok) throw new Error(response.statusText)
      this.orderBefore = slugs
    } catch (error) {
      // The order on screen is now a lie — the next load would undo it. Say so
      // rather than letting the user find out on their next visit.
      console.error("Could not save the project order", error)
      this.element.dispatchEvent(new CustomEvent("sortable:failed", { bubbles: true }))
    }
  }

  #slugs() {
    return this.itemTargets.map((item) => item.dataset.slug)
  }

  #itemFor(node) {
    return node instanceof Element ? node.closest("[data-sortable-target='item']") : null
  }
}
