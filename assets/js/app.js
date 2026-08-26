import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/iex_code"
import topbar from "../vendor/topbar"
import TerminalHook from "./hooks/terminal_hook"

// Theme behavior lives in the supported application bundle rather than an
// inline layout script, so CSP can remain strict in desktop and release builds.
const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
const setTheme = (theme) => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme")
    document.documentElement.dataset.theme = systemTheme()
    document.documentElement.dataset.themeSource = "system"
  } else {
    localStorage.setItem("phx:theme", theme)
    document.documentElement.dataset.theme = theme
    document.documentElement.dataset.themeSource = "user"
  }
}

setTheme(localStorage.getItem("phx:theme") || "system")
window.addEventListener("storage", (event) => event.key === "phx:theme" && setTheme(event.newValue || "system"))
window.addEventListener("phx:set-theme", (event) => setTheme(event.target.dataset.phxTheme))
window.addEventListener("phx:reset_run_agent_guidance", (event) => {
  const agentId = event.detail?.agent_id
  if (!agentId) return

  const input = document.getElementById(`run-agent-steering-input-${agentId}`)
  if (input) {
    input.value = ""
    input.dispatchEvent(new Event("input", {bubbles: true}))
  }
})
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (document.documentElement.dataset.themeSource === "system") setTheme("system")
})

// LiveView may replace the focused trigger before a conditionally rendered
// dialog hook mounts. Capture the interaction target first so focus can still
// return to the control that opened the dialog.
let lastInteractionTarget = null
document.addEventListener("click", (event) => {
  if (!(event.target instanceof Element)) return

  const target = event.target.closest(
    "button, a[href], input, select, textarea, [role='button'], [tabindex]:not([tabindex='-1'])"
  )
  if (target instanceof HTMLElement) lastInteractionTarget = target
}, true)

const Hooks = {
  TerminalHook,
  ModalFocus: {
    mounted() {
      const activeElement = document.activeElement
      this.previouslyFocused = activeElement instanceof HTMLElement && activeElement !== document.body
        ? activeElement
        : lastInteractionTarget?.isConnected ? lastInteractionTarget : null
      this.previouslyFocusedId = this.previouslyFocused?.id || null
      this.background = document.getElementById("workspace-shell")
      if (this.background) this.background.inert = true
      this.background?.setAttribute("aria-hidden", "true")

      this.focusableSelector = [
        "a[href]",
        "button:not([disabled])",
        "input:not([disabled]):not([type='hidden'])",
        "select:not([disabled])",
        "textarea:not([disabled])",
        "[tabindex]:not([tabindex='-1'])"
      ].join(",")

      this.visibleFocusableElements = () => Array.from(
        this.el.querySelectorAll(this.focusableSelector)
      ).filter((element) => element.getClientRects().length > 0 && !element.inert)

      this.topmostModal = () => {
        const dialogs = Array.from(document.querySelectorAll("[data-modal-focus]"))
          .filter((dialog) => dialog.getClientRects().length > 0)
        return dialogs.at(-1)
      }

      this.focusInitialElement = () => {
        let preferred = null
        const selector = this.el.dataset.initialFocus

        if (selector) {
          try {
            preferred = this.el.querySelector(selector)
          } catch (_error) {
            // A malformed optional selector should not make the dialog unusable.
          }
        }

        const target = preferred || this.visibleFocusableElements()[0] || this.el
        target.focus({preventScroll: true})
      }

      this.handleKeyDown = (event) => {
        // The command palette is rendered after workspace dialogs and owns its
        // keyboard interaction while open.
        if (document.getElementById("command-palette-dialog")) return
        if (this.topmostModal() !== this.el) return

        if (event.key === "Escape") {
          const cancelEvent = this.el.dataset.cancelEvent
          if (!cancelEvent || this.closing) return

          event.preventDefault()
          event.stopPropagation()
          this.closing = true
          this.pushEvent(cancelEvent, {})
          return
        }

        if (event.key !== "Tab") return

        const focusable = this.visibleFocusableElements()
        if (focusable.length === 0) {
          event.preventDefault()
          this.el.focus()
          return
        }

        const first = focusable[0]
        const last = focusable[focusable.length - 1]

        if (!this.el.contains(document.activeElement)) {
          event.preventDefault()
          ;(event.shiftKey ? last : first).focus()
        } else if (event.shiftKey && document.activeElement === first) {
          event.preventDefault()
          last.focus()
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault()
          first.focus()
        }
      }

      document.addEventListener("keydown", this.handleKeyDown, true)
      this.initialFocusFrame = requestAnimationFrame(this.focusInitialElement)
    },
    destroyed() {
      document.removeEventListener("keydown", this.handleKeyDown, true)
      cancelAnimationFrame(this.initialFocusFrame)
      const previouslyFocused = this.previouslyFocused
      const previouslyFocusedId = this.previouslyFocusedId

      requestAnimationFrame(() => {
        const openModal = document.querySelector("[data-modal-focus]")
        if (!openModal && this.background) {
          this.background.inert = false
          this.background.removeAttribute("aria-hidden")
        }

        const focusTarget = previouslyFocused?.isConnected
          ? previouslyFocused
          : previouslyFocusedId && document.getElementById(previouslyFocusedId)
        focusTarget?.focus({preventScroll: true})
      })
    }
  },
  KeyboardSubmit: {
    mounted() {
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          this.el.form.requestSubmit()
        }
      })
    }
  },
  CodeCopy: {
    mounted() {
      // Snapshot the full innerHTML (icon + label) so the "Copied!" feedback
      // can be restored without destroying child elements such as SVG icons.
      this.originalHTML = this.el.innerHTML
      this.resetTimer = null
      this.el.setAttribute("aria-live", "polite")
      this.showCopyStatus = (message) => {
        this.el.textContent = message
        clearTimeout(this.resetTimer)
        this.resetTimer = setTimeout(() => {
          this.el.innerHTML = this.originalHTML
        }, 2000)
      }
      this.el.addEventListener("click", async () => {
        const text = this.el.getAttribute("data-code") || ""
        try {
          await navigator.clipboard.writeText(text)
          this.showCopyStatus("Copied")
        } catch (_error) {
          this.showCopyStatus("Copy failed")
        }
      })
    },
    destroyed() {
      clearTimeout(this.resetTimer)
    }
  },
  CommandPalette: {
    mounted() {
      this.lastFocusedElement = null
      this.paletteWasOpen = this.paletteIsOpen()

      this.handleKeyDown = (e) => {
        // Cmd+, or Ctrl+, opens the dedicated settings page.
        if ((e.metaKey || e.ctrlKey) && e.key === ",") {
          e.preventDefault()
          this.pushEvent("open_settings_page", {})
          return
        }

        // Cmd+K or Ctrl+K opens/toggles the palette
        if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K")) {
          e.preventDefault()

          if (!this.paletteIsOpen()) this.rememberFocus()

          this.pushEvent("toggle_command_palette", {})
          return
        }

        const dialog = this.paletteDialog()
        if (!dialog) return

        if (e.key === "Escape") {
          e.preventDefault()
          this.pushEvent("close_command_palette", {})
        } else if (e.key === "Tab") {
          this.trapFocus(e, dialog)
        } else if (e.key === "ArrowDown") {
          e.preventDefault()
          this.pushEvent("command_palette_navigate", {direction: "down"})
        } else if (e.key === "ArrowUp") {
          e.preventDefault()
          this.pushEvent("command_palette_navigate", {direction: "up"})
        } else if (e.key === "Enter" && document.activeElement?.id === "command-palette-input") {
          e.preventDefault()
          this.pushEvent("command_palette_execute_selected", {})
        }
      }

      window.addEventListener("keydown", this.handleKeyDown)

      this.handleEvent("focus_palette_input", () => {
        this.rememberFocus()

        setTimeout(() => {
          const input = document.getElementById("command-palette-input")
          if (input) {
            input.focus()
            input.select()
          }
        }, 30)
      })

      this.handleEvent("scroll_to_palette_item", ({index}) => {
        const el = document.getElementById(`palette-item-${index}`)
        if (el) {
          el.scrollIntoView({block: "nearest"})
        }
      })
    },
    updated() {
      const paletteIsOpen = this.paletteIsOpen()

      if (paletteIsOpen && !this.paletteWasOpen) this.rememberFocus()
      if (!paletteIsOpen && this.paletteWasOpen) this.restoreFocus()

      this.paletteWasOpen = paletteIsOpen
    },
    destroyed() {
      window.removeEventListener("keydown", this.handleKeyDown)
      if (this.paletteWasOpen) this.restoreFocus()
    },
    paletteDialog() {
      return document.getElementById("command-palette-dialog")
    },
    paletteIsOpen() {
      return Boolean(this.paletteDialog())
    },
    rememberFocus() {
      const activeElement = document.activeElement
      const dialog = this.paletteDialog()

      if (
        !this.lastFocusedElement &&
        activeElement instanceof HTMLElement &&
        activeElement !== document.body &&
        (!dialog || !dialog.contains(activeElement))
      ) {
        this.lastFocusedElement = activeElement
      }
    },
    restoreFocus() {
      const element = this.lastFocusedElement
      this.lastFocusedElement = null

      requestAnimationFrame(() => {
        if (element?.isConnected) element.focus()
      })
    },
    trapFocus(event, dialog) {
      const focusable = Array.from(dialog.querySelectorAll(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
      )).filter((element) => (
        element.getAttribute("tabindex") !== "-1" && element.getClientRects().length > 0
      ))

      if (focusable.length === 0) {
        event.preventDefault()
        dialog.focus()
        return
      }

      const first = focusable[0]
      const last = focusable[focusable.length - 1]

      if (!dialog.contains(document.activeElement)) {
        event.preventDefault()
        const target = event.shiftKey ? last : first
        target.focus()
      } else if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Top progress bar on page loads / navigations
topbar.config({barColors: {0: "#ff5e3a"}, shadowColor: "rgba(0, 0, 0, 0.3)"})
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300))
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide())

// Track the underlying Phoenix socket with its supported channel callbacks.
liveSocket.socket.onOpen(() => document.body.classList.remove("phx-disconnected"))
liveSocket.socket.onClose(() => document.body.classList.add("phx-disconnected"))
liveSocket.socket.onError(() => document.body.classList.add("phx-disconnected"))
window.addEventListener("offline", () => document.body.classList.add("phx-disconnected"))
window.addEventListener("online", () => document.body.classList.remove("phx-disconnected"))

liveSocket.connect()
window.liveSocket = liveSocket
