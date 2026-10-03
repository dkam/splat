import { Controller } from "@hotwired/stimulus"

// Re-prices the retention table as the days change, so the projected sizes
// follow the inputs before the form is saved. Bytes per day come from the
// server's storage snapshot; this only multiplies and formats them.
export default class extends Controller {
  static targets = ["row", "total"]

  update() {
    let total = 0
    let complete = true

    for (const row of this.rowTargets) {
      const days = Number(row.querySelector("input").value)
      const cell = row.querySelector("[data-projected]")

      if (!(days > 0)) {
        cell.textContent = "—"
        complete = false
        continue
      }

      const bytes = Number(row.dataset.bytesPerDay) * days
      cell.textContent = `~${humanSize(bytes)}`
      total += bytes
    }

    if (this.hasTotalTarget) {
      this.totalTarget.textContent = complete ? `~${humanSize(total)}` : "—"
    }
  }
}

// Matches Rails' number_to_human_size: base 1024, three significant digits.
function humanSize(bytes) {
  const units = ["Bytes", "KB", "MB", "GB", "TB", "PB"]
  let i = 0
  while (bytes >= 1024 && i < units.length - 1) {
    bytes /= 1024
    i++
  }
  return i === 0 ? `${Math.round(bytes)} Bytes` : `${Number(bytes.toPrecision(3))} ${units[i]}`
}
