import test from "node:test"
import assert from "node:assert/strict"
import TaskMoveFocus, {TaskMoveFocus as NamedTaskMoveFocus} from "./task_move_focus_hook.js"

const uuid = "123e4567-e89b-12d3-a456-426614174000"

function harness({element = null} = {}) {
  const listeners = new Map()
  const frames = new Map()
  let nextFrame = 1
  const calls = {lookups: [], focuses: [], cancelled: []}
  const fakeDocument = {
    getElementById(id) {
      calls.lookups.push(id)
      return element && id === element.id ? element : null
    }
  }
  const context = {
    el: {ownerDocument: fakeDocument},
    mounted() { return TaskMoveFocus.mounted.call(this) },
    destroyed() { return TaskMoveFocus.destroyed.call(this) }
  }
  const previous = {
    document: globalThis.document,
    requestAnimationFrame: globalThis.requestAnimationFrame,
    cancelAnimationFrame: globalThis.cancelAnimationFrame
  }
  globalThis.document = fakeDocument
  globalThis.requestAnimationFrame = callback => {
    const id = nextFrame++
    frames.set(id, callback)
    return id
  }
  globalThis.cancelAnimationFrame = id => {
    calls.cancelled.push(id)
    frames.delete(id)
  }
  context.handleEvent = (name, callback) => listeners.set(name, callback)
  return {
    context,
    calls,
    listeners,
    runFrame(id = 1) { frames.get(id)?.(); frames.delete(id) },
    restore() {
      globalThis.document = previous.document
      globalThis.requestAnimationFrame = previous.requestAnimationFrame
      globalThis.cancelAnimationFrame = previous.cancelAnimationFrame
    }
  }
}

test("named and default exports are the same hook object", () => {
  assert.strictEqual(TaskMoveFocus, NamedTaskMoveFocus)
})

test("mounted registers exactly one focus_task handler", () => {
  const h = harness()
  try {
    TaskMoveFocus.mounted.call(h.context)
    assert.deepEqual([...h.listeners.keys()], ["focus_task"])
  } finally { h.restore() }
})

test("valid card payload waits one RAF then focuses with preventScroll", () => {
  const target = {id: `task-card-${uuid}`, isConnected: true, focus: options => h.calls.focuses.push(options)}
  const h = harness({element: target})
  try {
    TaskMoveFocus.mounted.call(h.context)
    h.listeners.get("focus_task")({id: target.id})
    assert.deepEqual(h.calls.lookups, [target.id])
    assert.deepEqual(h.calls.focuses, [])
    h.runFrame()
    assert.deepEqual(h.calls.focuses, [{preventScroll: true}])
  } finally { h.restore() }
})

test("malformed, trigger, non-UUID and missing payloads are no-ops", () => {
  const h = harness()
  try {
    TaskMoveFocus.mounted.call(h.context)
    const handler = h.listeners.get("focus_task")
    for (const payload of [null, {}, {id: "move-task-trigger-" + uuid}, {id: "task-card-not-a-uuid"}, {id: `task-card-${uuid}-extra`}]) handler(payload)
    assert.deepEqual(h.calls.lookups, [])
    assert.deepEqual(h.calls.focuses, [])
  } finally { h.restore() }
})

test("a newer valid event cancels the prior frame and wins", () => {
  const first = {id: `task-card-${uuid}`, isConnected: true, focus: () => h.calls.focuses.push("first")}
  const secondId = "123e4567-e89b-12d3-a456-426614174001"
  const second = {id: `task-card-${secondId}`, isConnected: true, focus: options => h.calls.focuses.push(options)}
  const h = harness({element: first})
  try {
    const originalGet = h.context.el.ownerDocument.getElementById
    h.context.el.ownerDocument.getElementById = id => id === first.id ? first : id === second.id ? second : originalGet(id)
    TaskMoveFocus.mounted.call(h.context)
    const handler = h.listeners.get("focus_task")
    handler({id: first.id})
    handler({id: second.id})
    assert.ok(h.calls.cancelled.length >= 1)
    h.runFrame(2)
    assert.deepEqual(h.calls.focuses, [{preventScroll: true}])
  } finally { h.restore() }
})

test("destroyed cancels pending RAF and is idempotent", () => {
  const target = {id: `task-card-${uuid}`, isConnected: true, focus: () => h.calls.focuses.push("focus")}
  const h = harness({element: target})
  try {
    TaskMoveFocus.mounted.call(h.context)
    h.listeners.get("focus_task")({id: target.id})
    TaskMoveFocus.destroyed.call(h.context)
    TaskMoveFocus.destroyed.call(h.context)
    assert.equal(h.calls.cancelled.length, 1)
    assert.deepEqual(h.calls.focuses, [])
  } finally { h.restore() }
})
