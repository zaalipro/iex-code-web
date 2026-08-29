import test from "node:test"
import assert from "node:assert/strict"
import {
  responsiveSheetOwnsFocus,
  responsiveSheetWillOwnFocus
} from "./responsive_sheet_hook.mjs"

function view(matches) {
  return {matchMedia(query) { assert.equal(query, "(max-width: 639px)"); return {matches} }}
}

test("CommandPalette delegates active mobile Escape and Tab ownership only", () => {
  const host = {dataset: {responsiveSheetActive: "true"}}
  assert.equal(responsiveSheetOwnsFocus(host, view(true)), true)
  assert.equal(responsiveSheetOwnsFocus(host, view(false)), false)
  host.dataset.responsiveSheetActive = "false"
  assert.equal(responsiveSheetOwnsFocus(host, view(true)), false)
})

test("CommandPalette delegates initial focus before mount only for controller-owned mobile sheets", () => {
  const host = {dataset: {sheetReturnOwner: "controller"}}
  assert.equal(responsiveSheetWillOwnFocus(host, view(true)), true)
  assert.equal(responsiveSheetWillOwnFocus(host, view(false)), false)
  host.dataset.sheetReturnOwner = "hook"
  assert.equal(responsiveSheetWillOwnFocus(host, view(true)), false)
})
