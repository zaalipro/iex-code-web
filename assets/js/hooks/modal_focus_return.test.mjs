import test from "node:test"
import assert from "node:assert/strict"
import {modalSheetReturnId, restoreModalFocus} from "./modal_focus_return.mjs"

test("desktop teardown reads the outcome-sensitive return ID after success updates it", () => {
  const host = {dataset: {sheetReturnId: "delete-subtask-trigger"}}
  const dialog = {closest: () => host}
  assert.equal(modalSheetReturnId(dialog), "delete-subtask-trigger")
  host.dataset.sheetReturnId = "task-detail-title"
  assert.equal(modalSheetReturnId(dialog), "task-detail-title")
})

test("desktop return prefers the connected opener", () => {
  const focused = []
  const opener = {isConnected: true, focus: options => focused.push(["opener", options])}
  const document = {getElementById: () => null}

  assert.equal(restoreModalFocus({document, previouslyFocused: opener}), opener)
  assert.deepEqual(focused, [["opener", {preventScroll: true}]])
})

test("desktop success falls back to the server-trusted updated sheet return target", () => {
  const focused = []
  const stable = {focus: options => focused.push(options)}
  const document = {getElementById: id => id === "task-detail-title" ? stable : null}

  assert.equal(
    restoreModalFocus({
      document,
      previouslyFocused: {isConnected: false},
      previouslyFocusedId: "deleted-trigger",
      fallbackReturnId: "task-detail-title"
    }),
    stable
  )
  assert.deepEqual(focused, [{preventScroll: true}])
})

test("missing desktop return targets are harmless", () => {
  assert.equal(restoreModalFocus({document: {getElementById: () => null}}), null)
})
