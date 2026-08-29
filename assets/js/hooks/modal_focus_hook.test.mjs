import test from "node:test"
import assert from "node:assert/strict"

import {createModalFocus} from "./modal_focus_hook.js"

class Media {
  constructor(matches) { this.matches = matches; this.listeners = new Set() }
  addEventListener(_event, listener) { this.listeners.add(listener) }
  removeEventListener(_event, listener) { this.listeners.delete(listener) }
  change(matches) { this.matches = matches; for (const listener of this.listeners) listener({matches}) }
}

function setup(matches, {sheetOwner = true} = {}) {
  const media = new Media(matches)
  const listeners = new Set()
  const target = {
    inert: false,
    attrs: new Map(),
    hasAttribute(name) { return this.attrs.has(name) },
    getAttribute(name) { return this.attrs.get(name) ?? null },
    setAttribute(name, value) { this.attrs.set(name, String(value)) },
    removeAttribute(name) { this.attrs.delete(name) }
  }
  const sheet = sheetOwner
    ? {dataset: {sheetBackgroundId: "workspace-shell", responsiveSheetActive: matches ? "true" : undefined}}
    : null
  const document = {
    body: {},
    activeElement: null,
    addEventListener(_event, listener) { listeners.add(listener) },
    removeEventListener(_event, listener) { listeners.delete(listener) },
    querySelectorAll() { return [] },
    getElementById(id) { return id === "workspace-shell" ? target : null }
  }
  const element = {
    id: "dialog",
    dataset: {initialFocus: ""},
    closest() { return sheet },
    querySelectorAll() { return [] },
    querySelector() { return null },
    contains() { return false },
    getClientRects() { return [{}] },
    focus() { document.activeElement = element }
  }
  const previousWindow = globalThis.window
  const previousDocument = globalThis.document
  const previousHTMLElement = globalThis.HTMLElement
  const previousRAF = globalThis.requestAnimationFrame
  const previousCancelRAF = globalThis.cancelAnimationFrame
  globalThis.window = {matchMedia: () => media}
  globalThis.document = document
  globalThis.HTMLElement = class {}
  globalThis.requestAnimationFrame = callback => { callback(); return 1 }
  globalThis.cancelAnimationFrame = () => {}
  const hook = createModalFocus()
  hook.el = element
  hook.pushEvent = () => {}
  hook.mounted()
  return {
    hook, media, target, listeners,
    restore() {
      hook.destroyed()
      globalThis.window = previousWindow
      globalThis.document = previousDocument
      globalThis.HTMLElement = previousHTMLElement
      globalThis.requestAnimationFrame = previousRAF
      globalThis.cancelAnimationFrame = previousCancelRAF
    }
  }
}

test("standalone ModalFocus retains full ownership at 639px without a ResponsiveSheet", () => {
  const h = setup(true, {sheetOwner: false})
  assert.equal(h.target.inert, true)
  assert.equal(h.listeners.size, 1)
  h.restore()
})

test("nested ModalFocus hands ownership after the outer ResponsiveSheet settles", () => {
  const h = setup(false)
  assert.equal(h.target.inert, true)
  assert.equal(h.listeners.size, 1)
  h.hook.coordinator.beforeMobileActivate()
  assert.equal(h.target.inert, false)
  assert.equal(h.listeners.size, 0)
  h.hook.coordinator.afterMobileDeactivate()
  assert.equal(h.target.inert, true)
  assert.equal(h.listeners.size, 1)
  h.restore()
})
