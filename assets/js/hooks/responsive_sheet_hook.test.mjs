import test from "node:test"
import assert from "node:assert/strict"
import ResponsiveSheet, {ResponsiveSheet as NamedResponsiveSheet} from "./responsive_sheet_hook.mjs"

class FakeTarget {
  constructor() { this.listeners = new Map() }
  addEventListener(type, listener, options) {
    const entries = this.listeners.get(type) || []
    entries.push({listener, options})
    this.listeners.set(type, entries)
  }
  removeEventListener(type, listener, options) {
    const entries = this.listeners.get(type) || []
    this.listeners.set(type, entries.filter(entry => entry.listener !== listener || entry.options !== options))
  }
  emit(type, event = {}) {
    const emitted = {
      key: undefined,
      shiftKey: false,
      defaultPrevented: false,
      propagationStopped: false,
      preventDefault() { this.defaultPrevented = true },
      stopPropagation() { this.propagationStopped = true },
      ...event
    }
    for (const {listener} of [...(this.listeners.get(type) || [])]) listener(emitted)
    return emitted
  }
  listenerCount(type) { return (this.listeners.get(type) || []).length }
}

class FakeElement extends FakeTarget {
  constructor(id, {dataset = {}, visible = true, disabled = false, inert = false} = {}) {
    super()
    this.id = id
    this.dataset = {...dataset}
    this.visible = visible
    this.disabled = disabled
    this.inert = inert
    this.children = []
    this.parentElement = null
    this.ownerDocument = null
    this.attributes = new Map()
    this.focusCalls = []
  }
  append(...children) {
    for (const child of children) {
      child.parentElement = this
      child.setOwnerDocument(this.ownerDocument)
      this.children.push(child)
    }
  }
  setOwnerDocument(document) {
    this.ownerDocument = document
    for (const child of this.children) child.setOwnerDocument(document)
  }
  contains(target) {
    return target === this || this.children.some(child => child.contains(target))
  }
  getClientRects() { return this.visible ? [{}] : [] }
  hasAttribute(name) {
    if (name === "disabled") return this.disabled
    return this.attributes.has(name)
  }
  getAttribute(name) { return this.attributes.get(name) ?? null }
  setAttribute(name, value) { this.attributes.set(name, String(value)) }
  removeAttribute(name) { this.attributes.delete(name) }
  focus(options) {
    this.focusCalls.push(options)
    if (this.ownerDocument) this.ownerDocument.activeElement = this
  }
  findById(id) {
    if (this.id === id) return this
    for (const child of this.children) {
      const found = child.findById(id)
      if (found) return found
    }
    return null
  }
  allDescendants() { return this.children.flatMap(child => [child, ...child.allDescendants()]) }
  querySelectorAll() { return this.allDescendants().filter(element => element.focusable) }
  querySelector(selector) {
    if (selector.startsWith("#")) return this.findById(selector.slice(1))
    if (selector === "[data-sheet-initial-focus]") {
      return this.allDescendants().find(element => element.dataset.sheetInitialFocus !== undefined) || null
    }
    return null
  }
}

class FakeMedia extends FakeTarget {
  constructor(matches) { super(); this.matches = matches; this.media = "(max-width: 639px)" }
  change(matches) { this.matches = matches; this.emit("change", {matches, media: this.media}) }
}

function setup({mobile = true, backgroundAria, backgroundInert = false, noFocusables = false} = {}) {
  const media = new FakeMedia(mobile)
  const document = new FakeTarget()
  const root = new FakeElement("root")
  const background = new FakeElement("workspace-shell", {inert: backgroundInert})
  if (backgroundAria !== undefined) background.setAttribute("aria-hidden", backgroundAria)
  const trigger = new FakeElement("open-sheet")
  trigger.focusable = true
  const sheet = new FakeElement("sheet", {dataset: {
    sheetCloseEvent: "close_sheet",
    sheetReturnId: "open-sheet",
    sheetBackgroundId: "workspace-shell"
  }})
  sheet.setAttribute("tabindex", "-1")
  const first = new FakeElement("first")
  const last = new FakeElement("last")
  first.focusable = !noFocusables
  last.focusable = !noFocusables
  first.dataset.sheetInitialFocus = ""
  sheet.append(first, last)
  root.append(background, trigger, sheet)
  root.setOwnerDocument(document)

  document.activeElement = trigger
  document.defaultView = {matchMedia(query) { assert.equal(query, "(max-width: 639px)"); return media }}
  document.getElementById = id => root.findById(id)

  const frames = new Map()
  const cancelled = []
  let frameId = 0
  document.defaultView.requestAnimationFrame = callback => { const id = ++frameId; frames.set(id, callback); return id }
  document.defaultView.cancelAnimationFrame = id => { cancelled.push(id); frames.delete(id) }
  const flushFrames = () => {
    const pending = [...frames.entries()]
    frames.clear()
    for (const [, callback] of pending) callback()
  }

  const pushed = []
  const hook = Object.create(ResponsiveSheet)
  hook.el = sheet
  hook.pushEvent = (event, payload) => pushed.push([event, payload])
  return {hook, document, media, root, background, trigger, sheet, first, last, frames, cancelled, flushFrames, pushed}
}

test("exports the named and default ResponsiveSheet hook", () => {
  assert.equal(ResponsiveSheet, NamedResponsiveSheet)
  assert.equal(typeof ResponsiveSheet.mounted, "function")
})

test("mobile mount isolates background, traps focus, and pushes Escape once", () => {
  const h = setup()
  h.hook.mounted()
  assert.equal(h.background.inert, true)
  assert.equal(h.background.getAttribute("aria-hidden"), "true")
  assert.equal(h.sheet.dataset.responsiveSheetActive, "true")
  assert.equal(h.document.listenerCount("keydown"), 1)
  assert.equal(h.frames.size, 1)
  h.flushFrames()
  assert.deepEqual(h.first.focusCalls, [{preventScroll: true}])

  h.document.activeElement = h.last
  const tab = h.document.emit("keydown", {key: "Tab"})
  assert.equal(tab.defaultPrevented, true)
  assert.equal(h.document.activeElement, h.first)
  h.document.activeElement = h.first
  h.document.emit("keydown", {key: "Tab", shiftKey: true})
  assert.equal(h.document.activeElement, h.last)

  const escape = h.document.emit("keydown", {key: "Escape"})
  h.document.emit("keydown", {key: "Escape"})
  assert.equal(escape.defaultPrevented, true)
  assert.equal(escape.propagationStopped, true)
  assert.deepEqual(h.pushed, [["close_sheet", {}]])
})

test("desktop mount is inert and media changes activate then fully clean up without focus return", () => {
  const h = setup({mobile: false})
  h.hook.mounted()
  assert.equal(h.background.inert, false)
  assert.equal(h.document.listenerCount("keydown"), 0)
  assert.equal(h.media.listenerCount("change"), 1)

  h.media.change(true)
  assert.equal(h.background.inert, true)
  assert.equal(h.document.listenerCount("keydown"), 1)
  h.media.change(false)
  assert.equal(h.background.inert, false)
  assert.equal(h.background.hasAttribute("aria-hidden"), false)
  assert.equal(h.document.listenerCount("keydown"), 0)
  h.flushFrames()
  assert.equal(h.trigger.focusCalls.length, 0)
})

test("cleanup restores the exact prior background state and composes sibling owners", () => {
  const h = setup({backgroundAria: "sentinel", backgroundInert: true})
  h.hook.mounted()
  const sibling = new FakeElement("sibling", {dataset: {
    sheetCloseEvent: "close_sibling",
    sheetReturnId: "open-sheet",
    sheetBackgroundId: "workspace-shell"
  }})
  sibling.setAttribute("tabindex", "-1")
  h.root.append(sibling)
  sibling.setOwnerDocument(h.document)
  const siblingHook = Object.create(ResponsiveSheet)
  siblingHook.el = sibling
  siblingHook.pushEvent = () => {}
  siblingHook.mounted()

  h.hook.destroyed()
  assert.equal(h.background.inert, true)
  assert.equal(h.background.getAttribute("aria-hidden"), "true")
  siblingHook.destroyed()
  assert.equal(h.background.inert, true)
  assert.equal(h.background.getAttribute("aria-hidden"), "sentinel")
})

test("only the topmost active sheet owns keyboard events", () => {
  const h = setup()
  h.hook.mounted()
  const sibling = new FakeElement("sibling", {dataset: {
    sheetCloseEvent: "close_sibling",
    sheetReturnId: "open-sheet",
    sheetBackgroundId: "workspace-shell"
  }})
  sibling.setAttribute("tabindex", "-1")
  h.root.append(sibling)
  sibling.setOwnerDocument(h.document)
  const pushed = []
  const siblingHook = Object.create(ResponsiveSheet)
  siblingHook.el = sibling
  siblingHook.pushEvent = (event, payload) => pushed.push([event, payload])
  siblingHook.mounted()

  h.document.emit("keydown", {key: "Escape"})
  assert.deepEqual(h.pushed, [])
  assert.deepEqual(pushed, [["close_sibling", {}]])
})

test("updated rebinds changed backgrounds and missing datasets degrade safely", () => {
  const h = setup()
  const second = new FakeElement("secondary-background")
  h.root.append(second)
  second.setOwnerDocument(h.document)
  h.hook.mounted()
  h.sheet.dataset.sheetBackgroundId = "secondary-background"
  h.hook.updated()
  assert.equal(h.background.inert, false)
  assert.equal(second.inert, true)

  h.sheet.dataset.sheetCloseEvent = ""
  h.hook.updated()
  assert.equal(second.inert, false)
  assert.equal(h.document.listenerCount("keydown"), 0)
})

test("destroyed cancels effects and returns focus only for an active mobile sheet", () => {
  const h = setup({noFocusables: true})
  h.hook.mounted()
  assert.equal(h.frames.size, 1)
  h.hook.destroyed()
  assert.equal(h.document.listenerCount("keydown"), 0)
  assert.equal(h.media.listenerCount("change"), 0)
  assert.equal(h.background.inert, false)
  assert.equal(h.sheet.dataset.responsiveSheetActive, undefined)
  assert.equal(h.frames.size, 1)
  h.flushFrames()
  assert.deepEqual(h.trigger.focusCalls, [{preventScroll: true}])

  h.hook.destroyed()
  h.flushFrames()
  assert.equal(h.trigger.focusCalls.length, 1)

  const desktop = setup({mobile: false})
  desktop.hook.mounted()
  desktop.hook.destroyed()
  desktop.flushFrames()
  assert.equal(desktop.trigger.focusCalls.length, 0)
})

test("controller-owned sheets do not race their controller's actual-opener return", () => {
  const h = setup()
  h.sheet.dataset.sheetReturnOwner = "controller"
  h.hook.mounted()
  h.hook.destroyed()
  h.flushFrames()
  assert.equal(h.trigger.focusCalls.length, 0)
})
