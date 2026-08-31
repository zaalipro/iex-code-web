import test from "node:test"
import assert from "node:assert/strict"
import CodeCopy from "./code_copy_hook.mjs"

function harness(label) {
  const attrs = new Map()
  const el = {
    dataset: {copyLabel: label},
    innerHTML: "<svg></svg>",
    setAttribute(name, value) { attrs.set(name, String(value)) },
    getAttribute(name) { return attrs.get(name) ?? null },
    addEventListener() {}
  }
  return {hook: {el}, el}
}

test("CodeCopy mirrors a patched copy label on mount and update", () => {
  const {hook, el} = harness("Copy lib/old.ex contents")
  CodeCopy.mounted.call(hook)
  assert.equal(el.getAttribute("aria-label"), "Copy lib/old.ex contents")

  el.dataset.copyLabel = "Copy lib/new.ex contents"
  CodeCopy.updated.call(hook)
  assert.equal(el.getAttribute("aria-label"), "Copy lib/new.ex contents")
  CodeCopy.destroyed.call(hook)
})
