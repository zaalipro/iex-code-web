import test from "node:test"
import assert from "node:assert/strict"
import {
  resolveTheme,
  themeCookie,
  expiredThemeCookie,
  applyTheme,
  setSystemTheme,
  setTheme
} from "./theme.mjs"

class FakeElement extends EventTarget {
  constructor() {
    super()
    this.dataset = {}
    this.style = {}
    this.attrs = new Map()
  }
  removeAttribute(name) {
    this.attrs.delete(name)
    if (name === "data-theme") delete this.dataset.theme
  }
  setAttribute(name, value) {
    this.attrs.set(name, value)
    if (name === "data-theme") this.dataset.theme = value
  }
}

function fakeEnv({prefersDark = false, protocol = "http:", metaContents = ["old"]} = {}) {
  const root = new FakeElement()
  const metas = metaContents.map((content, index) => ({
    content,
    media: index === 0 ? "" : "(prefers-color-scheme: light)"
  }))
  const cookieWrites = []
  const storage = new Map()
  const localStorage = {
    setItem(key, value) { storage.set(key, String(value)) },
    removeItem(key) { storage.delete(key) },
    getItem(key) { return storage.get(key) ?? null }
  }
  const mql = new EventTarget()
  mql.matches = prefersDark
  const document = {
    documentElement: root,
    get cookie() { return cookieWrites.at(-1) ?? "" },
    set cookie(value) { cookieWrites.push(value) },
    querySelectorAll(selector) {
      assert.equal(selector, 'meta[name="theme-color"]')
      return metas
    }
  }
  const window = new EventTarget()
  window.location = {protocol}
  window.CustomEvent = CustomEvent
  window.matchMedia = () => mql
  return {
    window,
    document,
    localStorage,
    matchMedia: () => mql,
    root,
    metas,
    cookieWrites,
    storage,
    mql
  }
}

test("resolveTheme gives explicit themes precedence over media preference", () => {
  assert.equal(resolveTheme({explicitTheme: "dark", prefersDark: false}), "dark")
  assert.equal(resolveTheme({explicitTheme: "light", prefersDark: true}), "light")
  assert.equal(resolveTheme({explicitTheme: "invalid", prefersDark: true}), "dark")
  assert.equal(resolveTheme({explicitTheme: null, prefersDark: false}), "light")
})

test("theme cookies include exact one-year flags and HTTPS Secure", () => {
  assert.equal(themeCookie("dark", {secure: false}), "iexcode_theme=dark; Path=/; Max-Age=31536000; SameSite=Strict")
  assert.equal(themeCookie("light", {secure: true}), "iexcode_theme=light; Path=/; Max-Age=31536000; SameSite=Strict; Secure")
  assert.equal(expiredThemeCookie({secure: false}), "iexcode_theme=; Path=/; Max-Age=0; SameSite=Strict")
  assert.equal(expiredThemeCookie({secure: true}), "iexcode_theme=; Path=/; Max-Age=0; SameSite=Strict; Secure")
})

test("applyTheme updates document, storage, every theme-color meta, and dispatches one event", () => {
  const env = fakeEnv({metaContents: ["one", "two"]})
  const events = []
  env.window.addEventListener("iexcode:theme-changed", event => events.push(event))
  applyTheme("dark", env)
  assert.equal(env.root.dataset.theme, "dark")
  assert.equal(env.root.dataset.themeSource, undefined)
  assert.equal(env.root.style.colorScheme, "dark")
  assert.equal(env.cookieWrites.at(-1), themeCookie("dark", {secure: false}))
  assert.equal(env.storage.get("phx:theme"), "dark")
  assert.deepEqual(env.metas.map(meta => meta.content), ["#171514", "#171514"])
  assert.equal(events.length, 1)
  assert.deepEqual(events[0].detail, {theme: "dark"})
})

test("setSystemTheme removes explicit state, expires cookie, resolves media, and dispatches one event", () => {
  const env = fakeEnv({prefersDark: true, metaContents: ["one", "two"]})
  env.root.dataset.theme = "light"
  env.root.dataset.themeSource = "system"
  env.storage.set("phx:theme", "light")
  const events = []
  env.window.addEventListener("iexcode:theme-changed", event => events.push(event))
  setSystemTheme(env)
  assert.equal(env.root.dataset.theme, undefined)
  assert.equal(env.root.dataset.themeSource, undefined)
  assert.equal(env.root.style.colorScheme, "light dark")
  assert.equal(env.cookieWrites.at(-1), expiredThemeCookie({secure: false}))
  assert.equal(env.storage.has("phx:theme"), false)
  assert.deepEqual(env.metas.map(meta => meta.content), ["#171514", "#EAE5DC"])
  assert.equal(events.length, 1)
  assert.deepEqual(events[0].detail, {theme: "dark"})
})

test("setTheme delegates to one adapter event and rejects invalid values", () => {
  const env = fakeEnv()
  const events = []
  env.window.addEventListener("iexcode:theme-changed", event => events.push(event))
  setTheme("light", env)
  assert.equal(events.length, 1)
  assert.equal(env.root.dataset.theme, "light")
  const before = env.cookieWrites.length
  setTheme("blue", env)
  assert.equal(env.cookieWrites.length, before)
  assert.equal(env.root.dataset.theme, "light")
})
