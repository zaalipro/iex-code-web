import test from "node:test"
import assert from "node:assert/strict"
import LocalTime from "./local_time_hook.js"

test("LocalTime mirrors the patched UTC instant into datetime on mount and update", () => {
  const attrs = new Map()
  const hook = {
    el: {
      dataset: {utc: "2026-08-28T12:30:00Z"},
      textContent: "server fallback",
      setAttribute(name, value) { attrs.set(name, String(value)) },
      getAttribute(name) { return attrs.get(name) ?? null }
    }
  }

  LocalTime.mounted.call(hook)
  assert.equal(hook.el.getAttribute("datetime"), "2026-08-28T12:30:00Z")

  hook.el.dataset.utc = "2026-08-29T09:45:00Z"
  LocalTime.updated.call(hook)
  assert.equal(hook.el.getAttribute("datetime"), "2026-08-29T09:45:00Z")
})
