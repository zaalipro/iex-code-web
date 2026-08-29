import test from "node:test"
import assert from "node:assert/strict"
import TaskMoveReturn, {TaskMoveReturn as NamedTaskMoveReturn} from "./task_move_return_hook.mjs"

const uuid = "123e4567-e89b-12d3-a456-426614174000"

class FakeTarget {
  constructor() { this.listeners = new Map() }
  addEventListener(type, listener) { this.listeners.set(type, [...(this.listeners.get(type) || []), listener]) }
  removeEventListener(type, listener) {
    this.listeners.set(type, (this.listeners.get(type) || []).filter(entry => entry !== listener))
  }
  emit(type, event = {}) {
    const emitted = {
      key: undefined,
      defaultPrevented: false,
      propagationStopped: false,
      preventDefault() { this.defaultPrevented = true },
      stopPropagation() { this.propagationStopped = true },
      ...event
    }
    for (const listener of [...(this.listeners.get(type) || [])]) listener(emitted)
    return emitted
  }
  listenerCount(type) { return (this.listeners.get(type) || []).length }
}

function harness({valid = true, invalidForm = false, invalidEvent = false} = {}) {
  const frames = new Map()
  const cancelled = []
  const pushed = []
  const focuses = []
  let nextFrame = 0
  const returnId = `move-task-trigger-${uuid}`
  let target
  const document = {getElementById: id => id === returnId ? target : null}
  target = {
    id: returnId,
    isConnected: true,
    focus(options) {
      focuses.push(options)
      document.activeElement = target
    }
  }
  const el = new FakeTarget()
  el.id = invalidForm ? `task-card-${uuid}` : `move-task-form-${uuid}`
  el.dataset = {
    taskId: uuid,
    taskMoveCancelEvent: invalidEvent ? "delete_task" : "cancel_task_move",
    taskMoveReturnId: valid ? returnId : `task-card-${uuid}`
  }
  el.ownerDocument = document

  const context = Object.create(TaskMoveReturn)
  context.el = el
  context.pushEvent = (event, payload) => pushed.push([event, payload])
  context.window = {
    requestAnimationFrame(callback) { const id = ++nextFrame; frames.set(id, callback); return id },
    cancelAnimationFrame(id) { cancelled.push(id); frames.delete(id) }
  }
  const flushFrames = () => {
    const pending = [...frames.entries()]
    frames.clear()
    for (const [, callback] of pending) callback()
  }

  return {context, document, el, target, pushed, focuses, frames, cancelled, flushFrames}
}

test("exports the named and default TaskMoveReturn hook", () => {
  assert.strictEqual(TaskMoveReturn, NamedTaskMoveReturn)
})

test("form-scoped Escape pushes one authoritative cancellation and returns focus after teardown", () => {
  const h = harness()
  h.context.mounted()
  assert.equal(h.el.listenerCount("keydown"), 1)

  const escape = h.el.emit("keydown", {key: "Escape"})
  h.el.emit("keydown", {key: "Escape"})
  assert.equal(escape.defaultPrevented, true)
  assert.equal(escape.propagationStopped, true)
  assert.deepEqual(h.pushed, [["cancel_task_move", {id: uuid}]])
  assert.deepEqual(h.focuses, [])

  h.context.destroyed()
  assert.equal(h.el.listenerCount("keydown"), 0)
  assert.equal(h.frames.size, 1)
  h.flushFrames()
  assert.deepEqual(h.focuses, [{preventScroll: true}])
  assert.equal(h.document.activeElement, h.target)
})

test("strict form, task, return, and event IDs reject malformed contracts", () => {
  for (const invalid of [harness({valid: false}), harness({invalidForm: true}), harness({invalidEvent: true})]) {
    invalid.context.mounted()
    invalid.el.emit("keydown", {key: "Escape"})
    invalid.context.destroyed()
    invalid.flushFrames()
    assert.deepEqual(invalid.pushed, [])
    assert.deepEqual(invalid.focuses, [])
  }

  const valid = harness()
  valid.context.mounted()
  valid.el.emit("keydown", {key: "Enter"})
  assert.deepEqual(valid.pushed, [])
})

test("non-cancel teardown never steals focus and destruction is idempotent", () => {
  const h = harness()
  h.context.mounted()
  h.context.destroyed()
  h.context.destroyed()
  h.flushFrames()
  assert.deepEqual(h.focuses, [])
  assert.deepEqual(h.cancelled, [])
})
