const canonicalUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

function scheduleFrame(hook, callback) {
  const request = hook.window?.requestAnimationFrame || globalThis.requestAnimationFrame
  return typeof request === "function" ? request(callback) : null
}

function cancelFrame(hook, frame) {
  if (frame === null || frame === undefined) return
  const cancel = hook.window?.cancelAnimationFrame || globalThis.cancelAnimationFrame
  if (typeof cancel === "function") cancel(frame)
}

export const TaskMoveReturn = {
  mounted() {
    this.destroyedOnce = false
    this.returnRequested = false
    this.returnFrame = null
    this.document = this.el?.ownerDocument || globalThis.document
    this.window = this.document?.defaultView || this.window || globalThis.window

    const taskId = this.el?.dataset?.taskId
    const returnId = this.el?.dataset?.taskMoveReturnId
    const validForm = canonicalUuid.test(taskId || "") && this.el?.id === `move-task-form-${taskId}`
    const validEvent = this.el?.dataset?.taskMoveCancelEvent === "cancel_task_move"
    this.taskId = validForm && validEvent ? taskId : null
    this.returnId = this.taskId && returnId === `move-task-trigger-${this.taskId}` ? returnId : null

    this.requestCancel = (event) => {
      if (this.destroyedOnce || !this.taskId || !this.returnId) return
      event.preventDefault?.()
      event.stopPropagation?.()
      if (this.returnRequested) return
      this.returnRequested = true
      this.pushEvent?.("cancel_task_move", {id: this.taskId})
    }

    this.handleKeyDown = (event) => {
      if (event.key === "Escape") this.requestCancel(event)
    }

    this.el?.addEventListener?.("keydown", this.handleKeyDown)
  },

  destroyed() {
    if (this.destroyedOnce) return
    this.destroyedOnce = true
    this.el?.removeEventListener?.("keydown", this.handleKeyDown)
    cancelFrame(this, this.returnFrame)
    this.returnFrame = null

    if (!this.returnRequested || !this.returnId) return
    this.returnFrame = scheduleFrame(this, () => {
      this.returnFrame = null
      const target = this.document?.getElementById?.(this.returnId)
      if (target?.isConnected !== false && typeof target?.focus === "function") {
        target.focus({preventScroll: true})
      }
    })
  }
}

export default TaskMoveReturn
