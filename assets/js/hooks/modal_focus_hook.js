import {responsiveSheetOwnsFocus} from "./responsive_sheet_hook.mjs"
import {modalSheetReturnId, restoreModalFocus} from "./modal_focus_return.mjs"
import {
  acquireModalBackground,
  acquireModalExposure,
  acquireModalIsolation,
  modalBackgroundId,
  releaseModalBackground,
  releaseModalExposure,
  releaseModalIsolation,
  topmostUsableModal
} from "./modal_focus_background.mjs"
import {createResponsiveModalFocusCoordinator} from "./responsive_modal_focus.mjs"

export function createModalFocus({getLastInteractionTarget = () => null} = {}) {
  return {
    mounted() {
      this.desktopOwned = false
      this.mobileSheetDelegated = responsiveSheetOwnsFocus(
        this.el.closest?.('[phx-hook="ResponsiveSheet"]'),
        window
      )
      this.sheet = this.el.closest?.('[phx-hook="ResponsiveSheet"]') || null
      this.setupDesktop = () => {
        if (this.desktopOwned) return
        this.desktopOwned = true
        const activeElement = document.activeElement
        this.previouslyFocused = activeElement instanceof HTMLElement && activeElement !== document.body &&
            !this.sheet?.contains?.(activeElement)
          ? activeElement
          : getLastInteractionTarget()?.isConnected ? getLastInteractionTarget() : null
        this.previouslyFocusedId = this.previouslyFocused?.id || null
        this.background = document.getElementById(modalBackgroundId(this.el))
        this.exposureTargets = acquireModalExposure(this.el, this)
        this.isolationTargets = acquireModalIsolation(this.el, this)
        if (this.isolationTargets.length === 0) {
          acquireModalBackground(this.background, this)
          this.isolationTargets = [this.background]
        }
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
        this.topmostModal = () => topmostUsableModal(
          document.querySelectorAll("[data-modal-focus]")
        )
        this.focusInitialElement = () => {
          let preferred = null
          const selector = this.el.dataset.initialFocus
          if (selector) {
            try { preferred = this.el.querySelector(selector) } catch (_error) { /* optional selector */ }
          }
          const target = preferred || this.visibleFocusableElements()[0] || this.el
          target.focus({preventScroll: true})
        }
        this.handleKeyDown = (event) => {
          if (!this.desktopOwned || document.getElementById("command-palette-dialog")) return
          if (this.topmostModal() !== this.el) return
          if (event.key === "Escape") {
            const cancelEvent = this.el.dataset.cancelEvent
            if (!cancelEvent || this.closing) return
            event.preventDefault(); event.stopPropagation(); this.closing = true
            this.pushEvent(cancelEvent, {})
            return
          }
          if (event.key !== "Tab") return
          const focusable = this.visibleFocusableElements()
          if (focusable.length === 0) {
            event.preventDefault(); this.el.focus(); return
          }
          const first = focusable[0], last = focusable[focusable.length - 1]
          if (!this.el.contains(document.activeElement)) {
            event.preventDefault(); (event.shiftKey ? last : first).focus()
          } else if (event.shiftKey && document.activeElement === first) {
            event.preventDefault(); last.focus()
          } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault(); first.focus()
          }
        }
        document.addEventListener("keydown", this.handleKeyDown, true)
        this.initialFocusFrame = requestAnimationFrame(this.focusInitialElement)
      }
      this.teardownDesktop = () => {
        if (!this.desktopOwned) return
        document.removeEventListener("keydown", this.handleKeyDown, true)
        cancelAnimationFrame(this.initialFocusFrame)
        this.initialFocusFrame = null
        if (this.isolationTargets.length === 1 && this.isolationTargets[0] === this.background && !this.el?.parentElement) {
          releaseModalBackground(this.background, this)
        } else {
          releaseModalIsolation(this.isolationTargets, this)
        }
        releaseModalExposure(this.exposureTargets, this)
        this.exposureTargets = []
        this.isolationTargets = []
        this.desktopOwned = false
      }
      this.coordinator = createResponsiveModalFocusCoordinator({
        activateDesktop: () => this.setupDesktop(),
        deactivateDesktop: () => this.teardownDesktop()
      })
      if (this.sheet) this.sheet.__responsiveModalFocusCoordinator = this.coordinator
      this.coordinator.mount(this.mobileSheetDelegated)
    },
    updated() {
      if (!this.sheet && !this.desktopOwned) this.coordinator?.afterMobileDeactivate()
    },
    destroyed() {
      const finalMode = this.coordinator?.destroy()
      if (this.sheet?.__responsiveModalFocusCoordinator === this.coordinator) {
        delete this.sheet.__responsiveModalFocusCoordinator
      }
      if (finalMode === "mobile") return
      const previouslyFocused = this.previouslyFocused
      const previouslyFocusedId = this.previouslyFocusedId
      const fallbackReturnId = modalSheetReturnId(this.el)
      requestAnimationFrame(() => {
        restoreModalFocus({document, previouslyFocused, previouslyFocusedId, fallbackReturnId})
      })
    }
  }
}

export default createModalFocus
