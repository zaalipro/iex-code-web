import test from "node:test"
import assert from "node:assert/strict"

import ResponsiveSheet from "./responsive_sheet_hook.mjs"
import {createModalFocus} from "./modal_focus_hook.js"

class Target {
  constructor() { this.listeners = new Map() }
  addEventListener(type, listener) { const list = this.listeners.get(type) || []; list.push(listener); this.listeners.set(type, list) }
  removeEventListener(type, listener) { this.listeners.set(type, (this.listeners.get(type) || []).filter(item => item !== listener)) }
  emit(type, event = {}) { for (const listener of [...(this.listeners.get(type) || [])]) listener(event) }
  count(type) { return (this.listeners.get(type) || []).length }
}

class Element {
  constructor(id, dataset = {}) { this.id = id; this.dataset = dataset; this.inert = false; this.attrs = new Map(); this.children = []; this.parentElement = null }
  append(child) { child.parentElement = this; child.ownerDocument = this.ownerDocument; this.children.push(child) }
  hasAttribute(name) { return this.attrs.has(name) }
  getAttribute(name) { return this.attrs.get(name) ?? null }
  setAttribute(name, value) { this.attrs.set(name, String(value)) }
  removeAttribute(name) { this.attrs.delete(name) }
  getClientRects() { return [{}] }
  querySelectorAll() { return [] }
  querySelector() { return null }
  contains(node) { return node === this || this.children.includes(node) }
  focus(options) { this.focusCalls = [...(this.focusCalls || []), options]; this.ownerDocument.activeElement = this }
}

class Media extends Target {
  constructor(matches) { super(); this.matches = matches }
  settle(matches, emit = true) { this.matches = matches; if (emit) this.emit("change", {matches}) }
}

function composed(initialMobile) {
  const media = new Media(initialMobile)
  const document = new Target()
  const background = new Element("scheduled-task-detail-modal")
  const trigger = new Element("delete-trigger")
  const sheet = new Element("sheet", {
    sheetCloseEvent: "cancel",
    sheetReturnId: trigger.id,
    sheetBackgroundId: background.id
  })
  const dialog = new Element("dialog", {cancelEvent: "cancel", initialFocus: ""})
  const elements = new Map([[background.id, background], [trigger.id, trigger], [sheet.id, sheet], [dialog.id, dialog]])
  document.body = {}
  document.activeElement = trigger
  document.defaultView = {
    matchMedia: () => media,
    requestAnimationFrame: callback => { callback(); return 1 },
    cancelAnimationFrame: () => {}
  }
  document.getElementById = id => elements.get(id) || null
  document.querySelectorAll = () => [dialog]
  sheet.ownerDocument = document
  dialog.ownerDocument = document
  sheet.append(dialog)
  background.ownerDocument = document
  trigger.ownerDocument = document
  dialog.closest = () => sheet

  const globals = [globalThis.window, globalThis.document, globalThis.HTMLElement, globalThis.requestAnimationFrame, globalThis.cancelAnimationFrame]
  globalThis.window = document.defaultView
  globalThis.document = document
  globalThis.HTMLElement = class {}
  globalThis.requestAnimationFrame = document.defaultView.requestAnimationFrame
  globalThis.cancelAnimationFrame = document.defaultView.cancelAnimationFrame

  const sheetHook = Object.assign(Object.create(ResponsiveSheet), {el: sheet, pushEvent() {}})
  sheetHook.mounted()
  const modalHook = Object.assign(createModalFocus(), {el: dialog, pushEvent() {}})
  modalHook.mounted()

  return {
    media, document, background, sheet, dialog, sheetHook, modalHook,
    restore() {
      modalHook.destroyed(); sheetHook.destroyed()
      ;[globalThis.window, globalThis.document, globalThis.HTMLElement, globalThis.requestAnimationFrame, globalThis.cancelAnimationFrame] = globals
    }
  }
}

for (const order of ["inner-first", "outer-first"]) {
  test(`639 to 640 composed handoff is deterministic (${order})`, () => {
    const h = composed(true)
    h.media.settle(false, false)
    if (order === "inner-first") h.modalHook.updated()
    h.media.emit("change", {matches: false})
    if (order === "outer-first") h.modalHook.updated()
    assert.equal(h.background.inert, true)
    assert.equal(h.background.getAttribute("aria-hidden"), "true")
    assert.equal(h.document.count("keydown"), 1)
    assert.equal(h.document.activeElement, h.dialog)
    h.restore()
  })

  test(`640 to 639 composed handoff is deterministic (${order})`, () => {
    const h = composed(false)
    h.media.settle(true, false)
    if (order === "inner-first") h.modalHook.updated()
    h.media.emit("change", {matches: true})
    if (order === "outer-first") h.modalHook.updated()
    assert.equal(h.background.inert, true)
    assert.equal(h.background.getAttribute("aria-hidden"), "true")
    assert.equal(h.document.count("keydown"), 1)
    h.restore()
  })
}
