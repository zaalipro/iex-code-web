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

function effectivelyInert(element) {
  if (!element) return false
  return Boolean(element?.inert) || effectivelyInert(element?.parentElement)
}

function effectivelyAriaHidden(element) {
  if (!element) return false
  return element?.getAttribute?.("aria-hidden") === "true" || effectivelyAriaHidden(element?.parentElement)
}

class FakeMedia extends FakeTarget {
  constructor(matches) { super(); this.matches = matches; this.media = "(max-width: 639px)" }
  change(matches) { this.matches = matches; this.emit("change", {matches, media: this.media}) }
}

function setup({mobile = true, viewportWidth, backgroundAria, backgroundInert = false, noFocusables = false, dialog = false, confirmationTopology = false} = {}) {
  const media = new FakeMedia(viewportWidth === undefined ? mobile : viewportWidth <= 639)
  const document = new FakeTarget()
  const root = new FakeElement("root")
  const background = new FakeElement("workspace-shell", {inert: backgroundInert})
  if (backgroundAria !== undefined) background.setAttribute("aria-hidden", backgroundAria)
  const trigger = new FakeElement("open-sheet")
  trigger.focusable = true
  const sheet = new FakeElement("sheet", {dataset: {
    sheetCloseEvent: "close_sheet",
    sheetReturnId: "open-sheet",
    sheetBackgroundId: "workspace-shell",
    ...(dialog ? {sheetDialog: "true"} : {})
  }})
  sheet.setAttribute("tabindex", "-1")
  const first = new FakeElement("first")
  const last = new FakeElement("last")
  first.focusable = !noFocusables
  last.focusable = !noFocusables
  first.dataset.sheetInitialFocus = ""
  sheet.append(first, last)
  const workspaceViews = new FakeElement("workspace-views")
  const missionControl = new FakeElement("mission-control")
  missionControl.focusable = true
  if (confirmationTopology) {
    workspaceViews.append(trigger)
    background.append(missionControl, workspaceViews)
    root.append(background, sheet)
  } else {
    root.append(background, trigger, sheet)
  }
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
  return {hook, document, media, root, background, workspaceViews, missionControl, trigger, sheet, first, last, frames, cancelled, flushFrames, pushed}
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

test("639 to 640 and 640 to 639 expose exact sheet ownership boundaries", () => {
  const mobile = setup({viewportWidth: 639})
  mobile.hook.mounted()
  assert.equal(mobile.sheet.dataset.responsiveSheetActive, "true")
  assert.equal(mobile.document.listenerCount("keydown"), 1)
  mobile.media.change(false)
  assert.equal(mobile.sheet.dataset.responsiveSheetActive, undefined)
  assert.equal(mobile.background.inert, false)
  assert.equal(mobile.document.listenerCount("keydown"), 0)

  const desktop = setup({viewportWidth: 640})
  desktop.hook.mounted()
  assert.equal(desktop.sheet.dataset.responsiveSheetActive, undefined)
  desktop.media.change(true)
  assert.equal(desktop.sheet.dataset.responsiveSheetActive, "true")
  assert.equal(desktop.background.inert, true)
  assert.equal(desktop.document.listenerCount("keydown"), 1)
})

test("breakpoint transitions coordinate desktop teardown before mobile and setup after mobile", () => {
  const h = setup({viewportWidth: 640})
  const transitions = []
  h.sheet.__responsiveModalFocusCoordinator = {
    beforeMobileActivate: () => transitions.push(["before-mobile", h.document.listenerCount("keydown")]),
    afterMobileDeactivate: () => transitions.push(["after-mobile", h.document.listenerCount("keydown")])
  }
  h.hook.mounted()
  h.media.change(true)
  h.media.change(false)
  assert.deepEqual(transitions, [["before-mobile", 0], ["after-mobile", 0]])
})

test("mobile-only dialog semantics activate and restore truthfully", () => {
  const h = setup({mobile: false, dialog: true})
  h.hook.mounted()
  assert.equal(h.sheet.getAttribute("role"), null)
  assert.equal(h.sheet.getAttribute("aria-modal"), null)
  h.media.change(true)
  assert.equal(h.sheet.getAttribute("role"), "dialog")
  assert.equal(h.sheet.getAttribute("aria-modal"), "true")
  h.media.change(false)
  assert.equal(h.sheet.getAttribute("role"), null)
  assert.equal(h.sheet.getAttribute("aria-modal"), null)
})

test("drawer semantics are modal at 639 and nonmodal at 640, 1279, and 1280", () => {
  for (const [width, mobile] of [[639, true], [640, false], [1279, false], [1280, false]]) {
    const h = setup({viewportWidth: width, dialog: true})
    h.hook.mounted()

    assert.equal(h.sheet.getAttribute("role"), mobile ? "dialog" : null, `${width}px role`)
    assert.equal(h.sheet.getAttribute("aria-modal"), mobile ? "true" : null, `${width}px modal`)
    assert.equal(h.background.inert, mobile, `${width}px background inert`)
    assert.equal(h.document.listenerCount("keydown"), mobile ? 1 : 0, `${width}px focus owner`)

    h.hook.destroyed()
  }
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
  assert.equal(h.document.activeElement, h.trigger)

  h.hook.destroyed()
  h.flushFrames()
  assert.equal(h.trigger.focusCalls.length, 1)

  const desktop = setup({mobile: false})
  desktop.hook.mounted()
  desktop.hook.destroyed()
  desktop.flushFrames()
  assert.equal(desktop.trigger.focusCalls.length, 0)
})

test("mobile cancellation restores the full workspace shell and initiating delete trigger", () => {
  const h = setup({confirmationTopology: true})
  h.sheet.dataset.sheetReturnId = h.trigger.id
  h.hook.mounted()

  assert.equal(h.background.contains(h.missionControl), true)
  assert.equal(h.workspaceViews.contains(h.trigger), true)
  assert.equal(h.background.inert, true)
  assert.equal(h.background.getAttribute("aria-hidden"), "true")
  assert.equal(effectivelyInert(h.workspaceViews), true)
  assert.equal(effectivelyInert(h.missionControl), true)
  assert.equal(effectivelyAriaHidden(h.workspaceViews), true)
  assert.equal(effectivelyAriaHidden(h.missionControl), true)

  h.hook.destroyed()
  assert.equal(h.background.inert, false)
  assert.equal(h.background.hasAttribute("aria-hidden"), false)
  assert.equal(effectivelyInert(h.workspaceViews), false)
  assert.equal(effectivelyInert(h.missionControl), false)
  h.flushFrames()
  assert.deepEqual(h.trigger.focusCalls, [{preventScroll: true}])
})

test("mobile success reads the updated stable return ID before teardown", () => {
  const h = setup({confirmationTopology: true})
  const stable = new FakeElement("task-detail-title")
  stable.focusable = true
  h.workspaceViews.append(stable)
  stable.setOwnerDocument(h.document)
  h.hook.mounted()

  h.sheet.dataset.sheetReturnId = stable.id
  h.hook.destroyed()
  h.flushFrames()

  assert.deepEqual(h.trigger.focusCalls, [])
  assert.deepEqual(stable.focusCalls, [{preventScroll: true}])
  assert.equal(h.document.activeElement, stable)
  assert.equal(h.background.inert, false)
  assert.equal(h.background.hasAttribute("aria-hidden"), false)
})

test("controller-owned sheets do not race their controller's actual-opener return", () => {
  const h = setup()
  h.sheet.dataset.sheetReturnOwner = "controller"
  h.hook.mounted()
  h.hook.destroyed()
  h.flushFrames()
  assert.equal(h.trigger.focusCalls.length, 0)
})

test("empty sheets focus their host and repeated sync stays single-listener", () => {
  const h = setup({noFocusables: true})
  h.sheet.querySelector = () => null
  h.hook.mounted()
  h.hook.sync()
  h.hook.updated()
  assert.equal(h.document.listenerCount("keydown"), 1)
  assert.equal(h.media.listenerCount("change"), 1)
  h.flushFrames()
  assert.deepEqual(h.sheet.focusCalls, [{preventScroll: true}])
})

test("changed close and return datasets take effect without leaking prior ownership", () => {
  const h = setup()
  const alternate = new FakeElement("alternate-return")
  alternate.focusable = true
  h.root.append(alternate)
  alternate.setOwnerDocument(h.document)
  h.hook.mounted()
  h.sheet.dataset.sheetCloseEvent = "close_changed"
  h.sheet.dataset.sheetReturnId = "alternate-return"
  h.hook.updated()
  h.document.emit("keydown", {key: "Escape"})
  assert.deepEqual(h.pushed, [["close_changed", {}]])
  h.hook.destroyed()
  h.flushFrames()
  assert.deepEqual(alternate.focusCalls, [{preventScroll: true}])
})

test("missing and disconnected return targets are harmless", () => {
  const missing = setup()
  missing.sheet.dataset.sheetReturnId = "missing"
  missing.hook.mounted()
  missing.hook.destroyed()
  assert.doesNotThrow(() => missing.flushFrames())

  const disconnected = setup()
  disconnected.trigger.isConnected = false
  disconnected.hook.mounted()
  disconnected.hook.destroyed()
  disconnected.flushFrames()
  assert.equal(disconnected.trigger.focusCalls.length, 0)
})
