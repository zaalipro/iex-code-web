import {formatLocalTime} from "../local_time.mjs"
import {syncLocalTime} from "./ignored_host_semantics.mjs"

function renderLocalTime(hook) {
  syncLocalTime(hook.el)
  try {
    const locale = navigator.languages?.[0] || navigator.language
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    const result = formatLocalTime(hook.el.dataset.utc, locale, timeZone, hook.serverFallback)
    hook.el.textContent = result.text
  } catch (_error) {
    hook.el.textContent = hook.serverFallback
  }
}

export const LocalTime = {
  mounted() {
    this.serverFallback = this.el.textContent
    renderLocalTime(this)
  },

  updated() {
    renderLocalTime(this)
  }
}

export default LocalTime
