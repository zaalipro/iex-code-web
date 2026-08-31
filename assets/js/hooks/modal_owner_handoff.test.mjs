import test from "node:test"
import assert from "node:assert/strict"
import ResponsiveSheet from "./responsive_sheet_hook.mjs"
import {acquireModalBackground, releaseModalBackground} from "./modal_focus_background.mjs"

function element(dataset = {}) {
  const attrs = new Map()
  return {
    dataset: {...dataset}, inert: false,
    hasAttribute: name => attrs.has(name),
    getAttribute: name => attrs.get(name) ?? null,
    setAttribute: (name, value) => attrs.set(name, String(value)),
    removeAttribute: name => attrs.delete(name),
    querySelectorAll: () => [], querySelector: () => null,
    removeEventListener() {}, focus() {}
  }
}

test("new ModalFocus owner mounted before old mobile sheet destroy keeps background isolated", () => {
  const background = element()
  const sheet = element({sheetCloseEvent: "close", sheetReturnId: "open", sheetBackgroundId: "workspace-shell"})
  const document = {addEventListener() {}, removeEventListener() {}, activeElement: null}
  const hook = Object.create(ResponsiveSheet)
  Object.assign(hook, {
    el: sheet, document, window: {}, destroyedOnce: false, dialogSemantics: false,
    closeSent: false, focusFrame: null, active: false, handleKeyDown() {}
  })

  hook.activate(background)
  const modalOwner = {}
  acquireModalBackground(background, modalOwner)
  hook.deactivate()
  assert.equal(background.inert, true)
  assert.equal(background.getAttribute("aria-hidden"), "true")
  releaseModalBackground(background, modalOwner)
  assert.equal(background.inert, false)
  assert.equal(background.getAttribute("aria-hidden"), null)
})
