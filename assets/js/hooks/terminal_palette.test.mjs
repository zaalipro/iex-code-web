import test from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"

const css = readFileSync(new URL("../../css/app.css", import.meta.url), "utf8")

function rgb(hex) {
  const value = Number.parseInt(hex.slice(1), 16)
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255]
}
function luminance(hex) {
  return rgb(hex).map(channel => {
    const value = channel / 255
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
  }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0)
}
function contrast(a, b) {
  const [lighter, darker] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (lighter + 0.05) / (darker + 0.05)
}
function themeToken(theme, token) {
  const block = css.match(new RegExp(`:root\\[data-theme="${theme}"\\] \\{([\\s\\S]*?)\\n\\}`))[1]
  return block.match(new RegExp(`--${token}:\\s*(#[0-9A-Fa-f]{6})`))[1]
}

test("terminal submit uses AA-safe explicit theme tokens", () => {
  assert.match(css, /\.sf-terminal-submit[^}]*background: var\(--sf-live-text\)[^}]*color: var\(--sf-instrument-raised\)/)
  for (const theme of ["dark", "light"]) {
    assert.ok(contrast(themeToken(theme, "sf-live-text"), themeToken(theme, "sf-instrument-raised")) >= 4.5)
  }
})

test("terminal wrapper and ownership copy remain theme-tokenized", () => {
  assert.match(css, /\.sf-terminal-viewport[^}]*background: var\(--sf-canvas-deep\)/)
  assert.doesNotMatch(css.match(/\.sf-terminal-viewport[^}]*}/)[0], /#0b0e10|rgb\(255 255 255/)
  assert.match(css, /\.sf-terminal-lock-banner, \.sf-terminal-agent-banner[^}]*font-size: \.875rem/)
})
