import test from "node:test"
import assert from "node:assert/strict"
import {initialTerminalLifecycle, transitionTerminalLifecycle} from "./terminal_lifecycle.mjs"

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
