import test from "node:test"
import assert from "node:assert/strict"
import InstrumentDeck, {createInstrumentDeckHook} from "./instrument_deck_hook.mjs"

const surfaces = ["kanban", "swarm", "research", "calendar", "changes", "chat", "files", "terminal"]

class FakeTarget {
  constructor() { this.listeners = new Map() }
  addEventListener(type, fn, options) {
    const entries = this.listeners.get(type) || []
    entries.push({fn, options})
    this.listeners.set(type, entries)
  }
  removeEventListener(type, fn, options) {
    const entries = this.listeners.get(type) || []
    this.listeners.set(type, entries.filter(entry => entry.fn !== fn || entry.options !== options))
  }
  emit(type, event = {}) {
    for (const {fn} of [...(this.listeners.get(type) || [])]) fn({type, detail: {}, ...event})
  }
  listenerCount(type) { return (this.listeners.get(type) || []).length }
}

class FakeElement extends FakeTarget {
  constructor(id, {dataset = {}, visible = true, disabled = false, order = []} = {}) {
    super()
    this.id = id
    this.dataset = {...dataset}
    this.visible = visible
    this.disabled = disabled
    this.order = order
    this.children = []
    this.parentElement = null
    this.scrollTop = 0
    this.inert = false
  }
  append(...children) {
    for (const child of children) {
      child.parentElement = this
      this.children.push(child)
    }
  }
  contains(target) {
    return target === this || this.children.some(child => child.contains(target))
  }
  closest(selector) {
    let element = this
    while (element) {
      if (selector === "[data-instrument-surface]" && element.dataset.instrumentSurface !== undefined) return element
      if (selector === "[data-palette-surface]" && element.dataset.paletteSurface !== undefined) return element
      if (selector === '[id^="return-to-instrument-deck-"]' && element.id.startsWith("return-to-instrument-deck-")) return element
      element = element.parentElement
    }
    return null
  }
  querySelector(selector) {
    if (selector.startsWith("#")) return this.findById(selector.slice(1))
    return null
  }
  findById(id) {
    if (this.id === id) return this
    for (const child of this.children) {
      const found = child.findById(id)
      if (found) return found
    }
    return null
  }
  getClientRects() { return this.visible ? [{}] : [] }
  hasAttribute(name) { return name === "disabled" ? this.disabled : false }
  focus(options) { this.order.push(["focus", this.id, options]) }
}

class FakeStorage {
  constructor(entries = {}) { this.values = new Map(Object.entries(entries)); this.removed = []; this.throwing = false }
  getItem(key) { if (this.throwing) throw new Error("denied"); return this.values.get(key) ?? null }
  setItem(key, value) { if (this.throwing) throw new Error("quota"); this.values.set(key, String(value)) }
  removeItem(key) { if (this.throwing) throw new Error("denied"); this.removed.push(key); this.values.delete(key) }
}

function setup({activeView = "deck", project = "project-1", session = "session-1", local = {}, stored = {}, historyState = {type: "patch", id: 4, position: 2}, includeDeck = true} = {}) {
  const order = []
  const shell = new FakeElement("workspace-shell", {dataset: {activeView, projectId: project, sessionId: session}, order})
  const deck = new FakeElement("instrument-deck", {order})
  deck.scrollTop = 37
  const heading = new FakeElement("instrument-deck-heading", {order})
  const cards = Object.fromEntries(surfaces.map(surface => [surface, new FakeElement(`instrument-card-${surface}`, {
    dataset: {instrumentSurface: surface}, order
  })]))
  deck.append(heading, ...Object.values(cards))
  if (includeDeck) shell.append(deck)

  const document = {
    activeElement: null,
    getElementById(id) { return shell.findById(id) },
    querySelector(selector) { return shell.querySelector(selector) }
  }
  const window = new FakeTarget()
  window.location = {href: "https://example.test/"}
  const historyCalls = []
  window.history = {
    state: historyState,
    replaceState(state, unused, href) { this.state = state; historyCalls.push({state, unused, href}) }
  }
  const localStorage = new FakeStorage(local)
  const sessionStorage = new FakeStorage(stored)
  let rafId = 0
  const frames = new Map()
  const cancelled = []
  const pushed = []
  const env = {
    window,
    document,
    localStorage,
    sessionStorage,
    now: () => 1_234,
    requestAnimationFrame(callback) { const id = ++rafId; frames.set(id, callback); return id },
    cancelAnimationFrame(id) { cancelled.push(id); frames.delete(id) },
    pushEvent(name, payload) { pushed.push([name, payload]) }
  }
  const hook = createInstrumentDeckHook(env)
  hook.el = shell
  const flushFrame = () => {
    const entries = [...frames.entries()]
    frames.clear()
    for (const [, callback] of entries) callback()
  }
  const click = target => shell.emit("click", {target})
  return {hook, env, shell, deck, heading, cards, document, window, localStorage, sessionStorage, historyCalls, order, pushed, frames, cancelled, flushFrame, click}
}

function state(scrollTop, focusedInstrumentId, capturedAt = 9) {
  return JSON.stringify({scrollTop, focusedInstrumentId, capturedAt})
}

test("exports both default and factory-created hook definitions", () => {
  assert.equal(typeof InstrumentDeck.mounted, "function")
  assert.equal(typeof createInstrumentDeckHook({}).mounted, "function")
})

test("mount computes exact keys and hydrates one closed stored surface per context", () => {
  const h = setup({local: {"iexcode:last-instrument:project-1:session-1": "research"}})
  h.hook.mounted()
  h.hook.updated()
  assert.equal(h.hook.lastInstrumentKey, "iexcode:last-instrument:project-1:session-1")
  assert.equal(h.hook.deckStateKey, "iexcode:deck-state:project-1:session-1")
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "research"}]])

  for (const invalid of ["", "deck", "unknown", " terminal "]) {
    const candidate = setup({local: {"iexcode:last-instrument:project-1:session-1": invalid}})
    candidate.hook.mounted()
    assert.deepEqual(candidate.pushed, [])
  }

  for (const [projectId, sessionId] of [["", "session-1"], ["project-1", ""]]) {
    const candidate = setup({project: projectId, session: sessionId})
    candidate.hook.mounted()
    assert.equal(candidate.hook.deckStateKey, null)
  }

  const missing = setup()
  delete missing.shell.dataset.projectId
  missing.hook.mounted()
  assert.equal(missing.hook.deckStateKey, null)

  h.shell.dataset.projectId = ""
  h.hook.updated()
  assert.equal(h.hook.lastInstrumentKey, null)
  assert.equal(h.hook.deckStateKey, null)
})

test("visible card activation writes raw closed surface and exact scoped state before navigation", () => {
  const h = setup()
  h.hook.mounted()
  h.flushFrame()
  h.deck.scrollTop = 72
  h.window.history.state = {type: "patch", id: 8, position: 3, backType: "push", other: "kept"}
  h.click(h.cards.terminal)

  assert.equal(h.localStorage.getItem("iexcode:last-instrument:project-1:session-1"), "terminal")
  assert.deepEqual(JSON.parse(h.sessionStorage.getItem("iexcode:deck-state:project-1:session-1")), {
    scrollTop: 72, focusedInstrumentId: "instrument-card-terminal", capturedAt: 1_234
  })
  assert.deepEqual(h.window.history.state, {
    type: "patch", id: 8, position: 3, backType: "push", other: "kept",
    iexcodeDeckState: {
      storageKey: "iexcode:deck-state:project-1:session-1",
      scrollTop: 72, focusedInstrumentId: "instrument-card-terminal", capturedAt: 1_234
    }
  })
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "terminal"}]])

  const malformed = new FakeElement("instrument-card-terminal", {dataset: {instrumentSurface: "unknown"}})
  h.deck.append(malformed)
  h.click(malformed)
  h.cards.chat.visible = false
  h.click(h.cards.chat)
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "terminal"}]])
})

test("deck page-loading captures focus/scroll, parses only closed canonical destinations, and workbench is inert", () => {
  const h = setup()
  h.hook.mounted()
  h.flushFrame()
  h.deck.scrollTop = 91
  h.document.activeElement = h.cards.files
  h.window.emit("phx:page-loading-start", {detail: {to: "/?view=files", kind: "patch"}})
  assert.equal(h.localStorage.getItem("iexcode:last-instrument:project-1:session-1"), "files")
  assert.deepEqual(JSON.parse(h.sessionStorage.getItem("iexcode:deck-state:project-1:session-1")), {
    scrollTop: 91, focusedInstrumentId: "instrument-card-files", capturedAt: 1_234
  })
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "files"}]])

  h.window.emit("phx:page-loading-start", {detail: {to: "/?view=files&extra=1"}})
  h.window.emit("phx:page-loading-start", {detail: {to: "https://evil.test/?view=chat"}})
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "files"}]])

  h.shell.dataset.activeView = "terminal"
  h.deck.scrollTop = 444
  h.window.emit("phx:page-loading-start", {detail: {to: "/?view=chat"}})
  assert.equal(JSON.parse(h.sessionStorage.getItem(h.hook.deckStateKey)).scrollTop, 91)
})

test("page-loading preserves the previous valid card focus when focus moved outside the deck", () => {
  const key = "iexcode:deck-state:project-1:session-1"
  const h = setup({stored: {[key]: state(12, "instrument-card-chat")}})
  h.hook.mounted()
  h.flushFrame()
  h.document.activeElement = new FakeElement("command-palette-input")
  h.deck.scrollTop = 60
  h.window.emit("phx:page-loading-start", {detail: {to: "/?view=terminal"}})
  assert.deepEqual(JSON.parse(h.sessionStorage.getItem(key)), {
    scrollTop: 60, focusedInstrumentId: "instrument-card-chat", capturedAt: 1_234
  })
})

test("palette page-loading uses only a closed palette surface signal", () => {
  const h = setup()
  h.hook.mounted()
  h.flushFrame()
  const palette = new FakeElement("palette-item-0", {dataset: {paletteSurface: "chat"}})
  h.shell.append(palette)
  h.document.activeElement = palette
  h.window.emit("phx:page-loading-start", {detail: {target: palette, to: "/logout"}})
  assert.equal(h.localStorage.getItem("iexcode:last-instrument:project-1:session-1"), "chat")
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "chat"}]])

  const malformed = new FakeElement("palette-item-1", {dataset: {paletteSurface: "settings"}})
  h.shell.append(malformed)
  h.window.emit("phx:page-loading-start", {detail: {target: malformed, to: "/settings#runtime"}})
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "chat"}]])
})

test("native beforeunload captures deck position without inventing a surface", () => {
  const h = setup()
  h.hook.mounted()
  h.flushFrame()
  h.deck.scrollTop = 118
  h.window.emit("beforeunload")
  assert.deepEqual(JSON.parse(h.sessionStorage.getItem(h.hook.deckStateKey)), {
    scrollTop: 118, focusedInstrumentId: null, capturedAt: 1_234
  })
  assert.equal(h.localStorage.getItem(h.hook.lastInstrumentKey), null)
})

test("Return captures the active workbench card while preserving stored deck scroll", () => {
  const key = "iexcode:deck-state:project-1:session-1"
  const h = setup({activeView: "changes", stored: {[key]: state(133, "instrument-card-kanban")}, includeDeck: false})
  const control = new FakeElement("return-to-instrument-deck-changes")
  h.shell.append(control)
  h.hook.mounted()
  h.click(control)
  assert.deepEqual(JSON.parse(h.sessionStorage.getItem(key)), {
    scrollTop: 133, focusedInstrumentId: "instrument-card-changes", capturedAt: 1_234
  })
})

test("matching popstate history wins over session while foreign or malformed history falls back", () => {
  const key = "iexcode:deck-state:project-1:session-1"
  for (const {historyValue, expected} of [
    {historyValue: {storageKey: key, scrollTop: 81, focusedInstrumentId: "instrument-card-research", capturedAt: 3}, expected: [81, "instrument-card-research"]},
    {historyValue: {storageKey: "iexcode:deck-state:other:session", scrollTop: 81, focusedInstrumentId: "instrument-card-research", capturedAt: 3}, expected: [22, "instrument-card-chat"]},
    {historyValue: "bad", expected: [22, "instrument-card-chat"]}
  ]) {
    const h = setup({activeView: "terminal", stored: {[key]: state(22, "instrument-card-chat")}})
    h.hook.mounted()
    h.window.emit("popstate", {state: {iexcodeDeckState: historyValue}})
    h.shell.dataset.activeView = "deck"
    h.shell.append(h.deck)
    h.hook.updated()
    h.flushFrame()
    assert.equal(h.deck.scrollTop, expected[0])
    assert.deepEqual(h.order.at(-1), ["focus", expected[1], {preventScroll: true}])
  }
})

test("popstate validates target history after a project/session dataset change", () => {
  const oldKey = "iexcode:deck-state:project-1:session-1"
  const newKey = "iexcode:deck-state:project-2:session-2"
  const h = setup({
    activeView: "terminal",
    stored: {[oldKey]: state(11, "instrument-card-chat"), [newKey]: state(22, "instrument-card-files")}
  })
  h.hook.mounted()
  h.window.emit("popstate", {state: {iexcodeDeckState: {
    storageKey: newKey,
    scrollTop: 88,
    focusedInstrumentId: "instrument-card-calendar",
    capturedAt: 7
  }}})
  h.shell.dataset.projectId = "project-2"
  h.shell.dataset.sessionId = "session-2"
  h.shell.dataset.activeView = "deck"
  h.shell.append(h.deck)
  h.hook.updated()
  h.flushFrame()
  assert.equal(h.deck.scrollTop, 88)
  assert.deepEqual(h.order.at(-1), ["focus", "instrument-card-calendar", {preventScroll: true}])
})

test("restoration scrolls before focus and falls back card to heading then scroller", () => {
  const key = "iexcode:deck-state:project-1:session-1"
  const h = setup({stored: {[key]: state(44, "instrument-card-files")}})
  let scroll = 0
  Object.defineProperty(h.deck, "scrollTop", {
    get() { return scroll },
    set(value) { scroll = value; h.order.push(["scroll", value]) }
  })
  h.hook.mounted()
  h.flushFrame()
  assert.deepEqual(h.order.slice(-2), [["scroll", 44], ["focus", "instrument-card-files", {preventScroll: true}]])

  h.sessionStorage.setItem(key, state(16, "instrument-card-files"))
  h.cards.files.visible = false
  h.shell.dataset.activeView = "terminal"
  h.hook.updated()
  h.shell.dataset.activeView = "deck"
  h.hook.updated()
  h.flushFrame()
  assert.deepEqual(h.order.at(-1), ["focus", "instrument-deck-heading", {preventScroll: true}])

  h.heading.visible = false
  h.shell.dataset.activeView = "terminal"
  h.hook.updated()
  h.shell.dataset.activeView = "deck"
  h.hook.updated()
  h.flushFrame()
  assert.deepEqual(h.order.at(-1), ["focus", "instrument-deck", {preventScroll: true}])
})

test("malformed saved state sanitizes scroll/focus independently and rejects invalid timestamps", () => {
  const key = "iexcode:deck-state:project-1:session-1"
  for (const {value, expectedScroll, expectedFocus} of [
    {value: "{", expectedScroll: 0, expectedFocus: "instrument-deck-heading"},
    {value: "null", expectedScroll: 0, expectedFocus: "instrument-deck-heading"},
    {value: state(-1, "instrument-card-chat"), expectedScroll: 0, expectedFocus: "instrument-card-chat"},
    {value: state(2, "arbitrary-id"), expectedScroll: 2, expectedFocus: "instrument-deck-heading"},
    {value: JSON.stringify({scrollTop: 2, focusedInstrumentId: null, capturedAt: "NaN"}), expectedScroll: 0, expectedFocus: "instrument-deck-heading"}
  ]) {
    const h = setup({stored: {[key]: value}})
    h.hook.mounted()
    h.flushFrame()
    assert.equal(h.deck.scrollTop, expectedScroll)
    assert.deepEqual(h.order.at(-1), ["focus", expectedFocus, {preventScroll: true}])
  }
})

test("key change hydrates once and removes only prior session state after a successful deck restore", () => {
  const oldKey = "iexcode:deck-state:project-1:session-1"
  const newKey = "iexcode:deck-state:project-2:session-2"
  const h = setup({local: {"iexcode:last-instrument:project-2:session-2": "calendar"}, stored: {[oldKey]: state(20, "instrument-card-kanban"), [newKey]: state(50, "instrument-card-calendar")}})
  h.hook.mounted()
  h.flushFrame()
  h.shell.dataset.projectId = "project-2"
  h.shell.dataset.sessionId = "session-2"
  h.hook.updated()
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "calendar"}]])
  assert.deepEqual(h.sessionStorage.removed, [])
  h.flushFrame()
  assert.deepEqual(h.sessionStorage.removed, [oldKey])
  assert.equal(h.sessionStorage.getItem(newKey), state(50, "instrument-card-calendar"))
  h.hook.updated()
  assert.deepEqual(h.pushed, [["restore_last_instrument", {surface: "calendar"}]])
})

test("failed restore retains prior-key cleanup and already-deck updates never steal focus", () => {
  const h = setup({includeDeck: false})
  h.hook.mounted()
  h.shell.dataset.projectId = "project-2"
  h.hook.updated()
  h.flushFrame()
  assert.deepEqual(h.sessionStorage.removed, [])

  const ordinary = setup()
  ordinary.hook.mounted()
  ordinary.flushFrame()
  ordinary.order.length = 0
  ordinary.hook.updated()
  ordinary.flushFrame()
  assert.deepEqual(ordinary.order, [])
  ordinary.shell.dataset.activeView = "terminal"
  ordinary.hook.updated()
  ordinary.shell.dataset.activeView = "deck"
  ordinary.hook.updated()
  ordinary.flushFrame()
  assert.equal(ordinary.order.filter(entry => entry[0] === "focus").length, 1)
})

test("destroyed removes owned listeners and cancels its single pending RAF", () => {
  const h = setup()
  h.hook.mounted()
  assert.equal(h.shell.listenerCount("click"), 1)
  assert.equal(h.window.listenerCount("phx:page-loading-start"), 1)
  assert.equal(h.window.listenerCount("beforeunload"), 1)
  assert.equal(h.window.listenerCount("popstate"), 1)
  assert.equal(h.frames.size, 1)
  h.hook.destroyed()
  assert.equal(h.shell.listenerCount("click"), 0)
  assert.equal(h.window.listenerCount("phx:page-loading-start"), 0)
  assert.equal(h.window.listenerCount("beforeunload"), 0)
  assert.equal(h.window.listenerCount("popstate"), 0)
  assert.equal(h.frames.size, 0)
  assert.equal(h.cancelled.length, 1)
  h.hook.destroyed()
})

test("throwing storage/history and direct one-frame restoration degrade without animation", () => {
  const h = setup()
  h.localStorage.throwing = true
  h.sessionStorage.throwing = true
  h.window.history = {get state() { throw new Error("denied") }, replaceState() { throw new Error("denied") }}
  assert.doesNotThrow(() => h.hook.mounted())
  assert.equal(h.frames.size, 1)
  assert.doesNotThrow(h.flushFrame)
  assert.equal(h.deck.scrollTop, 0)
  assert.equal(typeof h.deck.scrollTo, "undefined")
  assert.equal(h.frames.size, 0)
})
