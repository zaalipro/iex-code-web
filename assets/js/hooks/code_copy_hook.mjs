import {syncCopyLabel} from "./ignored_host_semantics.mjs"

const CodeCopy = {
  mounted() {
    this.originalHTML = this.el.innerHTML
    this.resetTimer = null
    this.el.setAttribute("aria-live", "polite")
    syncCopyLabel(this.el)
    this.showCopyStatus = (message) => {
      this.el.textContent = message
      clearTimeout(this.resetTimer)
      this.resetTimer = setTimeout(() => { this.el.innerHTML = this.originalHTML }, 2000)
    }
    this.handleClick = async () => {
      const text = this.el.getAttribute("data-code") || ""
      try {
        await navigator.clipboard.writeText(text)
        this.showCopyStatus("Copied")
      } catch (_error) {
        this.showCopyStatus("Copy failed")
      }
    }
    this.el.addEventListener("click", this.handleClick)
  },
  updated() { syncCopyLabel(this.el) },
  destroyed() {
    this.el.removeEventListener?.("click", this.handleClick)
    clearTimeout(this.resetTimer)
  }
}

export default CodeCopy
