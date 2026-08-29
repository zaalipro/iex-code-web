const taskCardId = /^task-card-[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

export const TaskMoveFocus = {
  mounted() {
    this.destroyedOnce = false
    this.focusFrame = null
    this.document = this.el?.ownerDocument || globalThis.document
    this.handleEvent("focus_task", payload => {
      if (this.destroyedOnce) return
      const id = payload && typeof payload === "object" ? payload.id : null
      if (typeof id !== "string" || !taskCardId.test(id)) return

      if (this.focusFrame !== null) {
        globalThis.cancelAnimationFrame?.(this.focusFrame)
        this.focusFrame = null
      }
      const target = this.document?.getElementById?.(id)
      if (!target) return
      this.focusFrame = globalThis.requestAnimationFrame?.(() => {
        this.focusFrame = null
        if (target.isConnected !== false && typeof target.focus === "function") {
          target.focus({preventScroll: true})
        }
      }) ?? null
    })
  },

  destroyed() {
    if (this.destroyedOnce) return
    this.destroyedOnce = true
    if (this.focusFrame !== null) {
      globalThis.cancelAnimationFrame?.(this.focusFrame)
      this.focusFrame = null
    }
  }
}

export default TaskMoveFocus
