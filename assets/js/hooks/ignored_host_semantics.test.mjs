import test from "node:test"
import assert from "node:assert/strict"
import {syncTerminalAriaDisabled} from "./ignored_host_semantics.mjs"

test("terminal ignored host mirrors patched input lock state", () => {
  const attrs = new Map()
  const el = {
    dataset: {inputLocked: "false"},
    setAttribute(name, value) { attrs.set(name, String(value)) },
    getAttribute(name) { return attrs.get(name) ?? null }
  }

  syncTerminalAriaDisabled(el)
  assert.equal(el.getAttribute("aria-disabled"), "false")
  el.dataset.inputLocked = "true"
  syncTerminalAriaDisabled(el)
  assert.equal(el.getAttribute("aria-disabled"), "true")
})
