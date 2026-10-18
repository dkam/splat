import { Controller } from "@hotwired/stimulus"

// The project page's cursor (ProjectTimeline#cursor_buckets). Point at any row
// and a band marks that bucket down the whole timeline, while the readout above
// lists what every row had in it. Also writes the local-time axis, which the
// server can't, not knowing the viewer's zone.
//
// The overlay target lies over exactly the strip column, so the pointer's place
// across it is its place in the window.
//
// A strip with data-timeline-href (the Events, Logs and issue rows) opens that
// list for the bucket clicked: the href with ?from=&to= set to the bucket.
export default class extends Controller {
  static targets = ["overlay", "cursor", "readout", "localTick", "zone"]
  static values = { buckets: Array, bucketSeconds: Number }

  connect() {
    this.idle = Array.from(this.readoutTarget.childNodes, (node) => node.cloneNode(true))
    this.index = null
    this.localize()
    this.element.addEventListener("pointermove", this.move)
    this.element.addEventListener("pointerleave", this.leave)
    this.element.addEventListener("click", this.open)
  }

  disconnect() {
    this.element.removeEventListener("pointermove", this.move)
    this.element.removeEventListener("pointerleave", this.leave)
    this.element.removeEventListener("click", this.open)
  }

  localize() {
    const daily = this.bucketSecondsValue >= 4 * 3600
    const options = daily ? { weekday: "short", day: "numeric" } : { hour: "2-digit", minute: "2-digit", hour12: false }
    this.localTickTargets.forEach((tick) => {
      tick.textContent = new Date(Number(tick.dataset.epoch) * 1000).toLocaleString(undefined, options)
    })
    if (this.hasZoneTarget) {
      const zone = new Date().toLocaleTimeString(undefined, { timeZoneName: "short" }).split(" ").pop()
      this.zoneTarget.textContent = zone
    }
  }

  move = (event) => {
    const index = this.indexAt(event)
    if (index === null) return this.leave()

    const lane = event.target.closest?.("[data-timeline-href]") || null
    if (index === this.index && lane === this.lane) return
    this.index = index
    this.lane = lane

    const count = this.bucketsValue.length
    this.cursorTarget.style.left = `${(index / count) * 100}%`
    this.cursorTarget.style.width = `${100 / count}%`
    this.cursorTarget.classList.remove("hidden")
    this.readoutTarget.replaceChildren(...this.describe(this.bucketsValue[index], lane))
  }

  open = (event) => {
    const lane = event.target.closest?.("[data-timeline-href]")
    const index = this.indexAt(event)
    if (!lane || index === null) return

    const bucket = this.bucketsValue[index]
    const url = new URL(lane.dataset.timelineHref, window.location.href)
    url.searchParams.set("from", new Date(bucket.t * 1000).toISOString())
    url.searchParams.set("to", new Date((bucket.t + this.bucketSecondsValue) * 1000).toISOString())
    if (window.Turbo) window.Turbo.visit(url.toString())
    else window.location.assign(url.toString())
  }

  // The bucket under the pointer, or null when it's outside the strips.
  indexAt(event) {
    const box = this.overlayTarget.getBoundingClientRect()
    const frac = (event.clientX - box.left) / box.width
    if (frac < 0 || frac >= 1 || event.clientY < box.top || event.clientY > box.bottom) return null
    return Math.floor(frac * this.bucketsValue.length)
  }

  leave = () => {
    if (this.index === null) return
    this.index = null
    this.lane = null
    this.cursorTarget.classList.add("hidden")
    this.readoutTarget.replaceChildren(...this.idle.map((node) => node.cloneNode(true)))
  }

  // One span per fact, built with textContent: issue and endpoint names come
  // from the monitored app.
  describe(bucket, lane) {
    const from = new Date(bucket.t * 1000)
    const to = new Date((bucket.t + this.bucketSecondsValue) * 1000)
    const parts = [[`${this.utc(from)}–${this.utc(to)}Z · ${this.local(from)} local`, "text-blue-700 dark:text-blue-300"]]
    for (const version of bucket.deploys) parts.push([`deploy ${this.release(version)}`, "text-violet-700 dark:text-violet-300"])

    parts.push([`${this.number(bucket.txn)} txn`])
    if (bucket.p95) parts.push([`p95 ${this.duration(bucket.p95)}`])
    const issues = bucket.issues.map(([id, n]) => `${id} ×${n}`).join(" ")
    parts.push([`${this.number(bucket.events)} ${bucket.events === 1 ? "event" : "events"}${issues ? `: ${issues}` : ""}`])
    bucket.endpoints.forEach(([name, p95]) => parts.push([`${name} p95 ${this.duration(p95)}`]))
    for (const [slug, status] of bucket.monitors) {
      if (status) parts.push([`${slug} ${status}`, "text-red-700 dark:text-red-300"])
      else parts.push([`${slug} ran`, "text-emerald-700 dark:text-emerald-300"])
    }

    if (lane) parts.push([`· ${lane.dataset.timelineHint}`, "underline decoration-dotted text-blue-700 dark:text-blue-300"])

    return parts.map(([text, className]) => {
      const span = document.createElement("span")
      span.textContent = text
      if (className) span.className = className
      return span
    })
  }

  utc(date) {
    const daily = this.bucketSecondsValue >= 86400
    return daily ? date.toISOString().slice(5, 10) : date.toISOString().slice(11, 16)
  }

  local(date) {
    return date.toLocaleString(undefined, { weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false })
  }

  // "19.12.3+5a6f4862…" → "19.12.3 · 5a6f486", as TimelineHelper#timeline_release
  // labels the deploy row.
  release(version) {
    const [name, build] = version.split("+")
    return build && /^[0-9a-f]{7,}$/i.test(build) ? `${name} · ${build.slice(0, 7)}` : version
  }

  number(value) {
    return Number(value || 0).toLocaleString()
  }

  duration(ms) {
    return ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.round(ms)}ms`
  }
}
