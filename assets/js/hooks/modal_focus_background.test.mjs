import test from "node:test"
import assert from "node:assert/strict"

import {
  acquireModalBackground,
  modalBackgroundId,
  releaseModalBackground,
  topmostUsableModal
} from "./modal_focus_background.mjs"

function background({inert = false, ariaHidden} = {}) {
  const attrs = new Map()
  if (ariaHidden !== undefined) attrs.set("aria-hidden", ariaHidden)
  return {
    inert,
    hasAttribute: name => attrs.has(name),
    getAttribute: name => attrs.get(name) ?? null,
    setAttribute: (name, value) => attrs.set(name, value),
    removeAttribute: name => attrs.delete(name)
  }
}

test("server-derived outer sheet background wins over workspace fallback", () => {
  const sheet = {dataset: {sheetBackgroundId: "scheduled-task-detail-modal"}}
  const dialog = {closest: selector => selector === "[data-sheet-background-id]" ? sheet : null}
  assert.equal(modalBackgroundId(dialog), "scheduled-task-detail-modal")
  assert.equal(modalBackgroundId({closest: () => null}), "workspace-shell")
})

test("background owners restore the exact inert and aria snapshot only after the final release", () => {
  const target = background({inert: true, ariaHidden: "false"})
  const first = {}
  const second = {}
  acquireModalBackground(target, first)
  acquireModalBackground(target, second)
  assert.equal(target.inert, true)
  assert.equal(target.getAttribute("aria-hidden"), "true")

  releaseModalBackground(target, first)
  assert.equal(target.getAttribute("aria-hidden"), "true")
  releaseModalBackground(target, second)
  assert.equal(target.inert, true)
  assert.equal(target.getAttribute("aria-hidden"), "false")
})

test("topmost selection excludes inert, aria-hidden, and geometrically hidden dialogs", () => {
  const usable = {inert: false, getAttribute: () => null, getClientRects: () => [{}]}
  const inert = {...usable, inert: true}
  const ariaHidden = {...usable, getAttribute: name => name === "aria-hidden" ? "true" : null}
  const hidden = {...usable, getClientRects: () => []}
  assert.equal(topmostUsableModal([usable, inert, ariaHidden, hidden]), usable)
})

test("dialogs inside an inert background are not competing modal owners", () => {
  const background = {inert: true, getAttribute: () => null, parentElement: null}
  const detail = {
    inert: false,
    getAttribute: () => null,
    getClientRects: () => [{}],
    parentElement: background
  }
  const confirmation = {inert: false, getAttribute: () => null, getClientRects: () => [{}], parentElement: null}
  assert.equal(topmostUsableModal([confirmation, detail]), confirmation)
})
