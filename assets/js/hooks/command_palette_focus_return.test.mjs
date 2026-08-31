import test from "node:test"
import assert from "node:assert/strict"
import {
  commandPaletteShouldRestoreFocus,
  resolveCommandPaletteFocusTarget
} from "./command_palette_focus_return.mjs"

test("command palette focus return keeps a connected prior opener", () => {
  const opener = {isConnected: true}
  const fallback = {id: "command-palette-trigger"}
  const document = {getElementById: () => fallback}

  assert.equal(resolveCommandPaletteFocusTarget({document, previouslyFocused: opener}), opener)
})

test("command palette focus return falls back when the prior opener is disconnected or missing", () => {
  const fallback = {id: "command-palette-trigger"}
  const document = {
    getElementById(id) {
      assert.equal(id, "command-palette-trigger")
      return fallback
    }
  }

  assert.equal(
    resolveCommandPaletteFocusTarget({document, previouslyFocused: {isConnected: false}}),
    fallback
  )
  assert.equal(resolveCommandPaletteFocusTarget({document}), fallback)
})

test("command palette focus return is null when no fallback exists", () => {
  const document = {getElementById: () => null}

  assert.equal(resolveCommandPaletteFocusTarget({document}), null)
})

test("command palette does not restore its opener during a modal handoff", () => {
  assert.equal(commandPaletteShouldRestoreFocus({querySelector: () => ({id: "new-modal"})}), false)
  assert.equal(commandPaletteShouldRestoreFocus({querySelector: () => null}), true)
})
