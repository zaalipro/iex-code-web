import {
  acquireModalBackground,
  acquireModalIsolation,
  releaseModalBackground,
  releaseModalIsolation
} from "./modal_focus_background.mjs"

const activeSheets = new Set()

const focusableSelector = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled]):not([type='hidden'])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[tabindex]:not([tabindex='-1'])"
].join(",")

function visible(element) {
  if (!element || element.disabled || element.inert) return false
  if (typeof element.getClientRects === "function") return element.getClientRects().length > 0
  return true
}

function nonblank(value) {
  return typeof value === "string" && value.trim() !== ""
}

export function responsiveSheetOwnsFocus(dialog, window = globalThis.window) {
  return dialog?.dataset?.responsiveSheetActive === "true" &&
    window?.matchMedia?.("(max-width: 639px)")?.matches === true
}

export function responsiveSheetWillOwnFocus(dialog, window = globalThis.window) {
  return dialog?.dataset?.sheetReturnOwner === "controller" &&
    window?.matchMedia?.("(max-width: 639px)")?.matches === true
}

function scheduleFrame(hook, callback) {
  const request = hook.window?.requestAnimationFrame || globalThis.requestAnimationFrame
  if (typeof request !== "function") return null
  return request(callback)
}

function cancelFrame(hook, frame) {
  if (frame === null || frame === undefined) return
  const cancel = hook.window?.cancelAnimationFrame || globalThis.cancelAnimationFrame
  if (typeof cancel === "function") cancel(frame)
}

function topmost() {
  return [...activeSheets].at(-1)
}

const ResponsiveSheet = {
  mounted() {
    this.destroyedOnce = false
    this.active = false
    this.background = null
    this.backgroundSnapshot = null
    this.isolationTargets = []
    this.desktopIsolation = false
    this.closeSent = false
    this.focusFrame = null
    this.returnFrame = null
    this.document = this.el?.ownerDocument || globalThis.document
    this.window = this.document?.defaultView || globalThis.window
    this.dialogSemantics = this.el?.dataset?.sheetDialog === "true"
    this.dialogSemanticsSnapshot = this.dialogSemantics
      ? {
          role: this.el.getAttribute?.("role"),
          ariaModal: this.el.getAttribute?.("aria-modal")
        }
      : null
    this.media = this.window?.matchMedia?.("(max-width: 639px)") || null
    this.handleMediaChange = () => this.sync()
    this.handleKeyDown = (event) => this.onKeyDown(event)
    this.media?.addEventListener?.("change", this.handleMediaChange)
    this.sync()
  },

  updated() {
    if (!this.destroyedOnce) this.sync()
  },

  sync() {
    if (this.destroyedOnce) return
    const mobile = this.media?.matches === true
    const datasets = this.el?.dataset || {}
    const valid = nonblank(datasets.sheetCloseEvent) && nonblank(datasets.sheetReturnId) &&
      nonblank(datasets.sheetBackgroundId)

    if (!valid) {
      this.deactivate()
      return
    }

    const nextBackground = this.document?.getElementById?.(datasets.sheetBackgroundId) || null
    if (!nextBackground) {
      this.deactivate()
      return
    }

    if (!mobile && datasets.sheetIsolateDesktop === "true") {
      if (this.active || (this.desktopIsolation && this.background !== nextBackground)) this.deactivate()
      if (!this.desktopIsolation) this.activateDesktopIsolation(nextBackground)
      return
    }

    if (!mobile) {
      this.deactivate()
      return
    }

    if ((this.active || this.desktopIsolation) && this.background !== nextBackground) this.deactivate()
    if (this.active) return

    this.activate(nextBackground)
  },

  activate(background) {
    this.el?.__responsiveModalFocusCoordinator?.beforeMobileActivate?.()
    this.background = background
    this.acquireIsolation(background)
    activeSheets.add(this)
    this.active = true
    if (this.dialogSemantics) {
      this.el.setAttribute?.("role", "dialog")
      this.el.setAttribute?.("aria-modal", "true")
    }
    this.closeSent = false
    this.el.dataset.responsiveSheetActive = "true"
    this.document?.addEventListener?.("keydown", this.handleKeyDown, true)

    this.focusFrame = scheduleFrame(this, () => {
      this.focusFrame = null
      if (!this.active) return
      this.focusInitial()
    })
  },

  activateDesktopIsolation(background) {
    this.background = background
    this.desktopIsolation = true
    this.acquireIsolation(background)
  },

  acquireIsolation(background) {
    this.isolationTargets = this.el?.dataset?.modalIsolation === "siblings"
      ? acquireModalIsolation(this.el, this)
      : []
    if (this.isolationTargets.length === 0) {
      acquireModalBackground(background, this)
      this.isolationTargets = [background]
    }
  },

  releaseIsolation() {
    if (this.isolationTargets.length === 1 && this.isolationTargets[0] === this.background && !this.el?.parentElement) {
      releaseModalBackground(this.background, this)
    } else {
      releaseModalIsolation(this.isolationTargets, this)
    }
    this.isolationTargets = []
    this.desktopIsolation = false
  },

  deactivate() {
    if (!this.active) {
      cancelFrame(this, this.focusFrame)
      this.focusFrame = null
      if (this.desktopIsolation) {
        this.releaseIsolation()
        this.background = null
      }
      return
    }
    cancelFrame(this, this.focusFrame)
    this.focusFrame = null
    this.document?.removeEventListener?.("keydown", this.handleKeyDown, true)
    activeSheets.delete(this)
    this.el?.removeAttribute?.("data-responsive-sheet-active")
    if (this.el?.dataset) delete this.el.dataset.responsiveSheetActive
    const background = this.background
    this.releaseIsolation()
    this.active = false
    if (this.dialogSemantics) {
      const role = this.dialogSemanticsSnapshot?.role
      const ariaModal = this.dialogSemanticsSnapshot?.ariaModal
      role === null || role === undefined
        ? this.el.removeAttribute?.("role")
        : this.el.setAttribute?.("role", role)
      ariaModal === null || ariaModal === undefined
        ? this.el.removeAttribute?.("aria-modal")
        : this.el.setAttribute?.("aria-modal", ariaModal)
    }
    this.background = null
    this.backgroundSnapshot = null
    this.backgroundRecord = null
    if (!this.destroyedOnce && this.media?.matches !== true) {
      this.el?.__responsiveModalFocusCoordinator?.afterMobileDeactivate?.()
    }
  },

  focusables() {
    return Array.from(this.el?.querySelectorAll?.(focusableSelector) || []).filter(visible)
  },

  focusInitial() {
    let target = null
    const preferred = this.el?.querySelector?.("[data-sheet-initial-focus]")
    if (visible(preferred)) target = preferred
    if (!target) target = this.focusables()[0]
    if (!target) {
      target = this.el
      target?.setAttribute?.("tabindex", "-1")
    }
    target?.focus?.({preventScroll: true})
  },

  onKeyDown(event) {
    if (!this.active || topmost() !== this) return
    if (event.key === "Escape") {
      event.preventDefault?.()
      event.stopPropagation?.()
      if (this.closeSent) return
      this.closeSent = true
      const closeEvent = this.el.dataset.sheetCloseEvent
      if (nonblank(closeEvent)) this.pushEvent?.(closeEvent, {})
      return
    }
    if (event.key !== "Tab") return
    const elements = this.focusables()
    if (elements.length === 0) {
      event.preventDefault?.()
      this.el?.focus?.({preventScroll: true})
      return
    }
    const first = elements[0]
    const last = elements.at(-1)
    if (!this.el.contains?.(this.document?.activeElement)) {
      event.preventDefault?.()
      ;(event.shiftKey ? last : first).focus?.({preventScroll: true})
    } else if (event.shiftKey && this.document?.activeElement === first) {
      event.preventDefault?.()
      last.focus?.({preventScroll: true})
    } else if (!event.shiftKey && this.document?.activeElement === last) {
      event.preventDefault?.()
      first.focus?.({preventScroll: true})
    }
  },

  destroyed() {
    if (this.destroyedOnce) return
    this.destroyedOnce = true
    const wasActive = this.active && this.media?.matches === true
    const returnId = this.el?.dataset?.sheetReturnId
    const controllerOwnsReturn = this.el?.dataset?.sheetReturnOwner === "controller"
    this.deactivate()
    this.media?.removeEventListener?.("change", this.handleMediaChange)
    this.media = null
    if (!wasActive || controllerOwnsReturn || !nonblank(returnId)) return
    this.returnFrame = scheduleFrame(this, () => {
      this.returnFrame = null
      const target = this.document?.getElementById?.(returnId)
      if (target?.isConnected !== false) target?.focus?.({preventScroll: true})
    })
  }
}

export {ResponsiveSheet}
export default ResponsiveSheet
