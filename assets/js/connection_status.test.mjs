import test from "node:test"
import assert from "node:assert/strict"
import {updateConnectionStatus} from "./connection_status.mjs"

function element(initial = {}) {
  const attrs = new Map()
  return {
    hidden: initial.hidden ?? false,
    dataset: {...initial.dataset},
    textContent: initial.textContent || "",
    classList: {
      values: new Set(initial.classes || []),
      toggle(name, enabled) { enabled ? this.values.add(name) : this.values.delete(name) },
      contains(name) { return this.values.has(name) }
    },
    setAttribute(name, value) { attrs.set(name, String(value)) },
    getAttribute(name) { return attrs.get(name) ?? null }
  }
}

test("connection state keeps the permanent strip truthful across disconnect and reconnect", () => {
  const status = element({hidden: true})
  const indicator = element({dataset: {state: "connected"}})
  const strip = element({textContent: "Connected", dataset: {state: "connected"}})
  const mark = element({classes: ["sf-success-mark"]})
  const body = element()
  const nodes = new Map([
    ["connection-status", status],
    ["mission-connection-indicator", indicator],
    ["mission-connection-status", strip],
    ["mission-connection-mark", mark]
  ])
  const document = {body, getElementById: id => nodes.get(id) || null}

  updateConnectionStatus(document, false, "offline")
  assert.equal(status.hidden, false)
  assert.equal(status.textContent, "Signal paused · reconnecting")
  assert.equal(strip.textContent, "Reconnecting")
  assert.equal(strip.dataset.state, "reconnecting")
  assert.equal(indicator.dataset.state, "reconnecting")
  assert.equal(mark.dataset.state, "reconnecting")
  assert.equal(mark.classList.contains("sf-success-mark"), false)
  assert.equal(body.classList.contains("phx-disconnected"), true)

  updateConnectionStatus(document, true, "socket-open")
  assert.equal(status.hidden, true)
  assert.equal(strip.textContent, "Connected")
  assert.equal(strip.dataset.state, "connected")
  assert.equal(indicator.dataset.state, "connected")
  assert.equal(mark.dataset.state, "connected")
  assert.equal(mark.classList.contains("sf-success-mark"), true)
  assert.equal(body.classList.contains("phx-disconnected"), false)
})
