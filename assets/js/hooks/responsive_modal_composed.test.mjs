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
  constructor(id, dataset = {}) { this.id = id; this.dataset = dataset; this.inert = false; this.isConnected = true; this.attrs = new Map(); this.children = []; this.parentElement = null }
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
  const frames = []
  const media = new Media(initialMobile)
  const document = new Target()
  const background = new Element("scheduled-task-detail-modal")
  const trigger = new Element("delete-trigger")
  const successTarget = new Element("changes-staging-title")
  const hunkSuccessTarget = new Element("changes-diff-panel")
  const sheet = new Element("sheet", {
    sheetCloseEvent: "cancel",
    sheetReturnId: trigger.id,
    sheetBackgroundId: background.id
  })
  const dialog = new Element("dialog", {cancelEvent: "cancel", initialFocus: ""})
  background.setAttribute("aria-hidden", "sentinel")
  const elements = new Map([
    [background.id, background],
    [trigger.id, trigger],
    [sheet.id, sheet],
    [dialog.id, dialog],
    [successTarget.id, successTarget],
    [hunkSuccessTarget.id, hunkSuccessTarget]
  ])
  document.body = {}
  document.activeElement = trigger
  document.defaultView = {
    matchMedia: () => media,
    requestAnimationFrame: callback => { frames.push(callback); return frames.length },
    cancelAnimationFrame: id => { frames[id - 1] = null }
  }
  document.getElementById = id => elements.get(id) || null
  document.removeElementById = id => elements.delete(id)
  document.querySelectorAll = () => [dialog]
  sheet.ownerDocument = document
  dialog.ownerDocument = document
  sheet.append(dialog)
  background.ownerDocument = document
  trigger.ownerDocument = document
  successTarget.ownerDocument = document
  hunkSuccessTarget.ownerDocument = document
  dialog.closest = () => sheet

  const globals = [globalThis.window, globalThis.document, globalThis.HTMLElement, globalThis.requestAnimationFrame, globalThis.cancelAnimationFrame]
  globalThis.window = document.defaultView
  globalThis.document = document
  globalThis.HTMLElement = Element
  globalThis.requestAnimationFrame = document.defaultView.requestAnimationFrame
  globalThis.cancelAnimationFrame = document.defaultView.cancelAnimationFrame

  const pushes = []
  const sheetHook = Object.assign(Object.create(ResponsiveSheet), {el: sheet, pushEvent(event) { pushes.push(event) }})
  sheetHook.mounted()
  const modalHook = Object.assign(createModalFocus(), {el: dialog, pushEvent(event) { pushes.push(event) }})
  modalHook.mounted()

  return {
    media, document, background, trigger, successTarget, hunkSuccessTarget, sheet, dialog, sheetHook, modalHook, pushes,
    flushFrames() { while (frames.length) { const frame = frames.shift(); if (frame) frame() } },
    destroy(order) {
      try {
        if (order === "inner-first") {
          modalHook.destroyed(); sheetHook.destroyed()
        } else {
          sheetHook.destroyed(); modalHook.destroyed()
        }
        this.flushFrames()
      } finally {
        ;[globalThis.window, globalThis.document, globalThis.HTMLElement, globalThis.requestAnimationFrame, globalThis.cancelAnimationFrame] = globals
      }
    }
  }
}

for (const [kind, targetKey] of [["file", "successTarget"], ["hunk", "hunkSuccessTarget"]]) {
  for (const mobile of [true, false]) {
    test(`successful ${kind} confirmation returns once to its stable target (${mobile ? "mobile" : "desktop"})`, () => {
      for (const order of ["inner-first", "outer-first"]) {
        const h = composed(mobile)
        const target = h[targetKey]
        h.sheet.dataset.sheetReturnId = target.id
        h.trigger.isConnected = false
        h.document.removeElementById(h.trigger.id)
        h.destroy(order)

        assert.equal(target.focusCalls?.length, 1)
        assert.equal(h.document.activeElement, target)
        assert.equal(h.trigger.focusCalls?.length || 0, 0)
        assert.equal(h.document.count("keydown"), 0)
        assert.equal(h.background.inert, false)
        assert.equal(h.background.getAttribute("aria-hidden"), "sentinel")
      }
    })
  }
}

function assertTeardown(h) {
  assert.equal(h.trigger.focusCalls?.length, 1)
  assert.equal(h.document.count("keydown"), 0)
  assert.equal(h.background.inert, false)
  assert.equal(h.background.hasAttribute("aria-hidden"), true)
  assert.equal(h.background.getAttribute("aria-hidden"), "sentinel")
}

for (const updateOrder of ["inner-first", "outer-first"]) {
  test(`639 to 640 composed handoff tears down with one return owner (${updateOrder} update)`, () => {
    for (const destroyOrder of ["inner-first", "outer-first"]) {
      const h = composed(true)
      h.media.settle(false, false)
      if (updateOrder === "inner-first") h.modalHook.updated()
      h.media.emit("change", {matches: false})
      if (updateOrder === "outer-first") h.modalHook.updated()
      assert.equal(h.background.inert, true)
      assert.equal(h.background.getAttribute("aria-hidden"), "true")
      assert.equal(h.document.count("keydown"), 1)
      h.flushFrames()
      assert.equal(h.document.activeElement, h.dialog)
      h.destroy(destroyOrder)
      assertTeardown(h)
    }
  })

  test(`640 to 639 composed handoff tears down with one return owner (${updateOrder} update)`, () => {
    for (const destroyOrder of ["inner-first", "outer-first"]) {
      const h = composed(false)
      h.media.settle(true, false)
      if (updateOrder === "inner-first") h.modalHook.updated()
      h.media.emit("change", {matches: true})
      if (updateOrder === "outer-first") h.modalHook.updated()
      assert.equal(h.background.inert, true)
      assert.equal(h.background.getAttribute("aria-hidden"), "true")
      assert.equal(h.document.count("keydown"), 1)
      h.flushFrames()
      h.destroy(destroyOrder)
      assertTeardown(h)
    }
  })
}

for (const kind of ["file", "hunk"]) {
  for (const mobile of [true, false]) {
    for (const order of ["inner-first", "outer-first"]) {
      test(`Escape ${kind} confirmation preserves opener (${mobile ? "mobile" : "desktop"}, ${order})`, () => {
        const h = composed(mobile)
        h.sheetHook.pushEvent = event => h.pushes.push(event)
        h.document.emit("keydown", {key: "Escape", preventDefault() { this.prevented = true }, stopPropagation() {}})
        h.sheet.isConnected = false
        h.dialog.isConnected = false
        h.destroy(order)
        assert.equal(h.trigger.focusCalls?.length, 1)
        assert.equal(h.successTarget.focusCalls?.length || 0, 0)
        assert.equal(h.pushes.filter(event => event === "cancel").length, 1)
        assert.equal(h.sheet.dataset.sheetReturnId, h.trigger.id)
      })

      test(`cancel click ${kind} confirmation preserves opener (${mobile ? "mobile" : "desktop"}, ${order})`, () => {
        const h = composed(mobile)
        h.pushes.push("cancel")
        h.sheet.isConnected = false
        h.dialog.isConnected = false
        h.destroy(order)
        assert.equal(h.trigger.focusCalls?.length, 1)
        assert.equal(h.successTarget.focusCalls?.length || 0, 0)
        assert.deepEqual(h.pushes, ["cancel"])
        assert.equal(h.sheet.dataset.sheetReturnId, h.trigger.id)
      })
    }
  }
}
