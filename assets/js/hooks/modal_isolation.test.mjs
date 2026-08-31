import test from "node:test"
import assert from "node:assert/strict"
import {acquireModalIsolation, releaseModalIsolation} from "./modal_focus_background.mjs"

class Element {
  constructor(id) { this.id = id; this.inert = false; this.parentElement = null; this.children = []; this.attrs = new Map() }
  append(...children) { for (const child of children) { child.parentElement = this; this.children.push(child) } }
  hasAttribute(name) { return this.attrs.has(name) }
  getAttribute(name) { return this.attrs.get(name) ?? null }
  setAttribute(name, value) { this.attrs.set(name, String(value)) }
  removeAttribute(name) { this.attrs.delete(name) }
}

test("modal isolation hides every sibling branch without inerting the dialog branch", () => {
  const body = new Element("body")
  const status = new Element("connection-status")
  const workspace = new Element("workspace-shell")
  const main = new Element("main")
  const mission = new Element("mission-strip")
  const views = new Element("workspace-views")
  const workbench = new Element("workbench")
  const dialog = new Element("task-detail-drawer")
  body.append(status, workspace)
  workspace.append(main)
  main.append(mission, views)
  views.append(workbench, dialog)

  const owner = {}
  const targets = acquireModalIsolation(dialog, owner, {root: body})
  for (const target of [status, mission, workbench]) {
    assert.equal(target.inert, true, target.id)
    assert.equal(target.getAttribute("aria-hidden"), "true", target.id)
  }
  for (const target of [body, workspace, main, views, dialog]) assert.equal(target.inert, false, target.id)

  releaseModalIsolation(targets, owner)
  for (const target of [status, mission, workbench]) {
    assert.equal(target.inert, false, target.id)
    assert.equal(target.getAttribute("aria-hidden"), null, target.id)
  }
})

test("palette over an existing modal leaves only the palette branch exposed", () => {
  const body = new Element("body")
  const workspace = new Element("workspace-shell")
  const existingModal = new Element("existing-modal")
  existingModal.setAttribute("aria-modal", "true")
  const paletteOverlay = new Element("palette-overlay")
  const palette = new Element("command-palette-dialog")
  paletteOverlay.append(palette)
  body.append(workspace, existingModal, paletteOverlay)

  const owner = {}
  const targets = acquireModalIsolation(palette, owner, {root: body})
  assert.equal(workspace.inert, true)
  assert.equal(existingModal.inert, true)
  assert.equal(paletteOverlay.inert, false)
  assert.equal(palette.inert, false)
  releaseModalIsolation(targets, owner)
})
