export function createResponsiveModalFocusCoordinator({activateDesktop, deactivateDesktop} = {}) {
  let mode = null
  let destroyed = false

  const enterDesktop = () => {
    if (destroyed || mode === "desktop") return
    mode = "desktop"
    activateDesktop?.()
  }

  const enterMobile = () => {
    if (destroyed || mode === "mobile") return
    if (mode === "desktop") deactivateDesktop?.()
    mode = "mobile"
  }

  return {
    mount(mobileOwned) {
      if (mobileOwned) enterMobile()
      else enterDesktop()
    },
    beforeMobileActivate() {
      enterMobile()
    },
    afterMobileDeactivate() {
      enterDesktop()
    },
    destroy() {
      if (destroyed) return mode
      destroyed = true
      if (mode === "desktop") deactivateDesktop?.()
      return mode
    },
    mode() { return mode }
  }
}
