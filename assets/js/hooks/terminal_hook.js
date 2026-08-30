import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { WebLinksAddon } from "@xterm/addon-web-links"
import { SearchAddon } from "@xterm/addon-search"
import { CanvasAddon } from "@xterm/addon-canvas"
import {resolveTheme} from "../theme.mjs"

/**
 * TerminalHook - High-performance interactive xterm.js LiveView Hook.
 *
 * Features:
 * - Theme-aware Signal Foundry palettes with in-place runtime recoloring
 * - FitAddon, WebLinksAddon, SearchAddon, and resilient CanvasAddon with fallback
 * - ResizeObserver with debouncing and zero-dimension protection
 * - Bidirectional input streaming (keystrokes, control signals, bracketed paste)
 * - Server push event handlers (output, history, clear, reset, find)
 * - Safe lifecycle teardown (observer disconnect, terminal disposal)
 */
export const TerminalHook = {
  mounted() {
    const theme = resolveTheme({
      explicitTheme: document.documentElement.dataset.theme,
      prefersDark: window.matchMedia("(prefers-color-scheme: dark)").matches
    })
    this.handleThemeChanged = (event) => this.applyTheme(event.detail?.theme)
    this.sessionId = this.el.dataset.sessionId || null
    this.initTerminal(theme)
    window.addEventListener("iexcode:theme-changed", this.handleThemeChanged)
  },

  themeFor(theme) {
    if (theme === "light") {
      return {
        background: "#FBF8F2",
        foreground: "#202321",
        cursor: "#D74628",
        cursorAccent: "#FBF8F2",
        selectionBackground: "rgba(215, 70, 40, 0.24)",
        selectionForeground: "#202321",
        selectionInactiveBackground: "rgba(32, 35, 33, 0.12)",
        black: "#202321",
        red: "#A8321F",
        green: "#42624F",
        yellow: "#775B18",
        blue: "#365E7D",
        magenta: "#6F4C76",
        cyan: "#34656A",
        white: "#DDD7CE",
        brightBlack: "#655F58",
        brightRed: "#D74628",
        brightGreen: "#60836E",
        brightYellow: "#977425",
        brightBlue: "#4E7695",
        brightMagenta: "#896390",
        brightCyan: "#4C7C81",
        brightWhite: "#FFFFFF"
      }
    }

    return {
      background: "#0B0E10",
      foreground: "#F4EFE7",
      cursor: "#F6532E",
      cursorAccent: "#0B0E10",
      selectionBackground: "rgba(246, 83, 46, 0.32)",
      selectionForeground: "#F4EFE7",
      selectionInactiveBackground: "rgba(244, 239, 231, 0.12)",
      black: "#0B0E10",
      red: "#FF7B72",
      green: "#9EBDA7",
      yellow: "#D6A84B",
      blue: "#78A9D1",
      magenta: "#C49ACB",
      cyan: "#78B7BA",
      white: "#D8D2C9",
      brightBlack: "#655F58",
      brightRed: "#FF9A8F",
      brightGreen: "#B2CEBA",
      brightYellow: "#E4BD68",
      brightBlue: "#94BDE0",
      brightMagenta: "#D7B2DC",
      brightCyan: "#94CBCE",
      brightWhite: "#FFFFFF"
    }
  },

  applyTheme(theme) {
    if (!this.term || (theme !== "dark" && theme !== "light")) return
    this.term.options.theme = this.themeFor(theme)
  },

  initTerminal(theme) {
    // 1. Initialize xterm.js Terminal Instance
    this.term = new Terminal({
      theme: this.themeFor(theme),
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
      fontSize: 13,
      lineHeight: 1.3,
      letterSpacing: 0,
      cursorBlink: true,
      cursorStyle: "block",
      cursorWidth: 2,
      scrollback: 10000,
      scrollSensitivity: 1,
      fastScrollModifier: "alt",
      fastScrollSensitivity: 5,
      allowTransparency: true,
      convertEol: true,
      windowsMode: false,
      smoothScrollDuration: 0,
      macOptionIsMeta: true,
      macOptionClickForcesSelection: true
    })

    // 3. Load Addons
    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)

    this.webLinksAddon = new WebLinksAddon((event, uri) => {
      window.open(uri, "_blank", "noopener,noreferrer")
    })
    this.term.loadAddon(this.webLinksAddon)

    this.searchAddon = new SearchAddon()
    this.term.loadAddon(this.searchAddon)

    // Canvas Addon with try/catch fallback to DOM renderer
    try {
      this.canvasAddon = new CanvasAddon()
      this.term.loadAddon(this.canvasAddon)
    } catch (err) {
      console.warn("[TerminalHook] Canvas renderer failed to load; using DOM renderer:", err)
      this.canvasAddon = null
    }

    // 4. Open Terminal in Host Element
    this.term.open(this.el)

    // 5. Custom Key Event Interceptor (macOS Cmd+C copy / Windows Ctrl+Shift+C copy)
    this.term.attachCustomKeyEventHandler((event) => {
      if (event.type === "keydown") {
        const isMac = typeof navigator !== "undefined" && navigator.platform && navigator.platform.toUpperCase().indexOf("MAC") >= 0
        const isCopy = isMac
          ? (event.metaKey && (event.key === "c" || event.key === "C"))
          : (event.ctrlKey && event.shiftKey && (event.key === "c" || event.key === "C"))

        if (isCopy && this.term.hasSelection()) {
          const selection = this.term.getSelection()
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(selection).catch(() => {})
          }
          return false
        }
      }
      return true
    })

    // 6. Keystroke Listener -> Push to Backend PTY
    this.inputLocked = () =>
      this.el?.dataset.inputLocked === "true" || this.el?.dataset.monitorOnly === "true"

    this.term.onData((data) => {
      if (!this.inputLocked()) this.pushEvent("terminal_input", { data })
    })

    // 7. Clipboard Paste Listener on Container
    this.handlePaste = (e) => {
      e.preventDefault()
      if (this.inputLocked()) return
      const text = (e.clipboardData || window.clipboardData).getData("text")
      if (text && text.length > 0) this.term.paste(text)
    }
    this.el.addEventListener("paste", this.handlePaste)

    // Click on container focuses the terminal
    this.handleClick = () => {
      if (this.term) {
        this.term.focus()
      }
    }
    this.el.addEventListener("click", this.handleClick)

    // 8. Server -> Client Push Event Handlers
    this.handleEvent("terminal_output", (payload) => {
      const data = typeof payload === "object" && payload !== null && payload.data !== undefined ? payload.data : payload
      if (typeof data === "string") {
        this.term.write(data)
      }
    })

    this.handleEvent("terminal_history", (payload) => {
      const history = typeof payload === "object" && payload !== null && payload.history !== undefined ? payload.history : payload
      if (typeof history === "string" && history.length > 0) {
        this.term.write(history)
      }
    })

    this.handleEvent("terminal_clear", () => {
      this.term.clear()
    })

    this.handleEvent("terminal_reset", () => {
      this.term.reset()
    })

    this.handleEvent("terminal_focus", () => {
      this.term.focus()
    })

    this.handleEvent("terminal_fit", () => {
      this.fitTerminal()
    })

    this.handleEvent("terminal_find_next", (payload) => {
      if (!payload || !payload.query || !this.searchAddon) return
      this.searchAddon.findNext(payload.query, {
        caseSensitive: !!payload.caseSensitive,
        wholeWord: !!payload.wholeWord,
        regex: !!payload.regex,
        incremental: !!payload.incremental
      })
    })

    this.handleEvent("terminal_find_previous", (payload) => {
      if (!payload || !payload.query || !this.searchAddon) return
      this.searchAddon.findPrevious(payload.query, {
        caseSensitive: !!payload.caseSensitive,
        wholeWord: !!payload.wholeWord,
        regex: !!payload.regex
      })
    })

    // 9. Resize Handling & ResizeObserver
    this.prevCols = null
    this.prevRows = null
    this.resizeRaf = null

    this.fitTerminal = () => {
      if (!this.el || !this.term || !this.fitAddon) return
      if (this.el.clientWidth <= 0 || this.el.clientHeight <= 0) return

      try {
        this.fitAddon.fit()
        const cols = this.term.cols
        const rows = this.term.rows

        if (cols > 0 && rows > 0 && (cols !== this.prevCols || rows !== this.prevRows)) {
          this.prevCols = cols
          this.prevRows = rows
          this.pushEvent("terminal_resize", { cols, rows })
        }
      } catch (err) {
        console.warn("[TerminalHook] Fit calculation error:", err)
      }
    }

    if (typeof ResizeObserver !== "undefined") {
      this.resizeObserver = new ResizeObserver(() => {
        if (this.resizeRaf) cancelAnimationFrame(this.resizeRaf)
        this.resizeRaf = requestAnimationFrame(() => {
          this.fitTerminal()
        })
      })
      this.resizeObserver.observe(this.el)
    }

    // Initial fit with small delay to ensure CSS layout settlement
    this.initialHandshakeTimer = setTimeout(() => {
      this.initialHandshakeTimer = null
      this.fitTerminal()
      if (this.term) this.term.focus()
      this.pushEvent("request_terminal_history", {})
    }, 50)
  },

  updated() {
    const nextSessionId = this.el.dataset.sessionId || null
    if (nextSessionId !== this.sessionId) {
      this.sessionId = nextSessionId
      if (this.term) this.term.reset()
      this.pushEvent("request_terminal_history", {})
    }
    if (this.fitTerminal) this.fitTerminal()
  },

  destroyed() {
    // 11. Cleanup & Teardown
    if (this.handleThemeChanged) {
      window.removeEventListener("iexcode:theme-changed", this.handleThemeChanged)
      this.handleThemeChanged = null
    }

    if (this.initialHandshakeTimer) {
      clearTimeout(this.initialHandshakeTimer)
      this.initialHandshakeTimer = null
    }

    if (this.resizeRaf) {
      cancelAnimationFrame(this.resizeRaf)
      this.resizeRaf = null
    }

    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
      this.resizeObserver = null
    }

    if (this.handlePaste && this.el) {
      this.el.removeEventListener("paste", this.handlePaste)
    }

    if (this.handleClick && this.el) {
      this.el.removeEventListener("click", this.handleClick)
    }

    if (this.term) {
      this.term.dispose()
      this.term = null
    }
  }
}

export default TerminalHook
