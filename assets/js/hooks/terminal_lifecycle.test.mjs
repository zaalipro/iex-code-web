import test from "node:test"
import assert from "node:assert/strict"
import {consumeInitialHandshake, initialTerminalLifecycle, transitionTerminalLifecycle} from "./terminal_lifecycle.mjs"

test("active mount timer consumes the pending handshake once", () => {
  const state = {...initialTerminalLifecycle(true), sessionId: "a"}
  const consumed = consumeInitialHandshake(state, "a", "a", 0, 0, true)
  assert.equal(consumed.requestHistory, true)
  const again = consumeInitialHandshake(consumed.state, "a", "a", 0, 0, true)
  assert.equal(again.requestHistory, false)
})

test("active to hidden before timer keeps history pending for reveal", () => {
  const initial = {...initialTerminalLifecycle(true), sessionId: "a"}
  const hidden = transitionTerminalLifecycle(initial, "a", false)
  const skipped = consumeInitialHandshake(hidden.state, "a", "a", 0, 0, false)
  assert.equal(skipped.requestHistory, false)
  const reveal = transitionTerminalLifecycle(skipped.state, "a", true)
  assert.equal(reveal.requestHistory, true)
})

test("active session switch before timer cannot double request new history", () => {
  const initial = {...initialTerminalLifecycle(true), sessionId: "a"}
  const switched = transitionTerminalLifecycle(initial, "b", true)
  const skipped = consumeInitialHandshake(switched.state, "a", "b", 0, 1, true)
  assert.equal(switched.requestHistory, true)
  assert.equal(skipped.requestHistory, false)
})

test("hidden-first activation requests history exactly once", () => {
  const initial = {...initialTerminalLifecycle(false), sessionId: "a"}
  const activated = transitionTerminalLifecycle(initial, "a", true)
  assert.equal(activated.reset, false)
  assert.equal(activated.requestHistory, true)
  const retained = transitionTerminalLifecycle(activated.state, "a", true)
  assert.equal(retained.requestHistory, false)
})

test("same-session roundtrip retains history without replay", () => {
  const active = {sessionId: "a", isActive: true, historyNeeded: false}
  const hidden = transitionTerminalLifecycle(active, "a", false)
  const reentered = transitionTerminalLifecycle(hidden.state, "a", true)
  assert.equal(reentered.reset, false)
  assert.equal(reentered.requestHistory, false)
})

test("active and hidden session switches reset once then replay once", () => {
  const active = {sessionId: "a", isActive: true, historyNeeded: false}
  const activeSwitch = transitionTerminalLifecycle(active, "b", true)
  assert.deepEqual({reset: activeSwitch.reset, request: activeSwitch.requestHistory}, {reset: true, request: true})

  const hidden = {sessionId: "a", isActive: false, historyNeeded: false}
  const hiddenSwitch = transitionTerminalLifecycle(hidden, "b", false)
  assert.deepEqual({reset: hiddenSwitch.reset, request: hiddenSwitch.requestHistory}, {reset: true, request: false})
  const reveal = transitionTerminalLifecycle(hiddenSwitch.state, "b", true)
  assert.deepEqual({reset: reveal.reset, request: reveal.requestHistory}, {reset: false, request: true})
})
