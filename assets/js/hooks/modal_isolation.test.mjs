import test from "node:test"
import assert from "node:assert/strict"
import {
  acquireModalExposure,
  acquireModalIsolation,
  releaseModalExposure,
  releaseModalIsolation
} from "./modal_focus_background.mjs"

class Element {
  constructor(id) { this.id = id; this.inert = false; this.parentElement = null; this.children = []; this.attrs = new Map() }
  append(...children) { for (const child of children) { child.parentElement = this; this.children.push(child) } }
  hasAttribute(name) { return this.attrs.has(name) }
  getAttribute(name) { return this.attrs.get(name) ?? null }
  setAttribute(name, value) { this.attrs.set(name, String(value)) }
  removeAttribute(name) { this.attrs.delete(name) }
}

function effectivelyIsolated(element) {
  let current = element
  while (current) {
    if (current.inert || current.getAttribute("aria-hidden") === "true") return true
    current = current.parentElement
  }
  return false
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

test("newer modal exposure outranks an underlying modal while lower-owner refresh cannot hide the top branch", () => {
  const body = new Element("body")
  const workspace = new Element("workspace-shell")
  const existingOverlay = new Element("goal-overlay")
  const existingDialog = new Element("goal-dialog")
  existingOverlay.append(existingDialog)
  body.append(workspace, existingOverlay)

  const underlyingOwner = {}
  const underlyingExposure = acquireModalExposure(existingDialog, underlyingOwner, {root: body})
  let underlyingTargets = acquireModalIsolation(existingDialog, underlyingOwner, {root: body})

  const paletteOverlay = new Element("palette-overlay")
  const palette = new Element("command-palette-dialog")
  paletteOverlay.append(palette)
  body.append(paletteOverlay)

  const paletteOwner = {}
  const paletteExposure = acquireModalExposure(palette, paletteOwner, {root: body})
  const paletteTargets = acquireModalIsolation(palette, paletteOwner, {root: body})
  underlyingTargets = acquireModalIsolation(existingDialog, underlyingOwner, {root: body})

  assert.equal(effectivelyIsolated(existingDialog), true)
  assert.equal(effectivelyIsolated(palette), false)

  releaseModalIsolation(paletteTargets, paletteOwner)
  releaseModalExposure(paletteExposure, paletteOwner)
  assert.equal(effectivelyIsolated(existingDialog), false)

  releaseModalIsolation(underlyingTargets, underlyingOwner)
  releaseModalExposure(underlyingExposure, underlyingOwner)
})

test("a nested top modal stays exposed when the underlying sheet refreshes its sibling isolation", () => {
  const body = new Element("body")
  const workspace = new Element("workspace-shell")
  const board = new Element("kanban-board")
  const drawer = new Element("task-detail-drawer")
  workspace.append(board, drawer)
  body.append(workspace)

  const underlyingOwner = {}
  acquireModalIsolation(drawer, underlyingOwner, {root: body})

  const confirmation = new Element("task-delete-confirmation")
  const confirmationDialog = new Element("task-delete-confirmation-dialog")
  confirmation.append(confirmationDialog)
  body.append(confirmation)

  const topOwner = {}
  const exposureTargets = acquireModalExposure(confirmationDialog, topOwner, {root: body})
  const topTargets = acquireModalIsolation(confirmationDialog, topOwner, {root: body})
  const refreshedUnderlyingTargets = acquireModalIsolation(drawer, underlyingOwner, {root: body})

  assert.equal(effectivelyIsolated(confirmationDialog), false)
  assert.equal(workspace.inert, true)
  assert.equal(board.inert, true)

  releaseModalIsolation(topTargets, topOwner)
  assert.equal(effectivelyIsolated(confirmationDialog), false)
  releaseModalExposure(exposureTargets, topOwner)
  assert.equal(confirmation.inert, true)
  assert.equal(confirmation.getAttribute("aria-hidden"), "true")

  releaseModalIsolation(refreshedUnderlyingTargets, underlyingOwner)
  assert.equal(board.inert, false)
  assert.equal(confirmation.inert, false)
})
