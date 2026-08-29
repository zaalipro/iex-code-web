import test from "node:test"
import assert from "node:assert/strict"

import {formatLocalTime} from "./local_time.mjs"

test("formats a fixed instant in the explicitly requested locale and zone", () => {
  assert.deepEqual(
    formatLocalTime("2026-08-28T12:30:00Z", "en-US", "Asia/Tbilisi", "fallback"),
    {ok: true, text: "Aug 28, 2026, 4:30 PM"}
  )
})

test("returns the exact opaque fallback for invalid and non-string input", () => {
  const fallback = "  UTC fallback!?  "

  assert.deepEqual(formatLocalTime("not-a-date", "en-US", "UTC", fallback), {
    ok: false,
    text: fallback
  })
  assert.deepEqual(formatLocalTime(null, "en-US", "UTC", fallback), {
    ok: false,
    text: fallback
  })
  assert.deepEqual(formatLocalTime("   ", "en-US", "UTC", fallback), {
    ok: false,
    text: fallback
  })
})

test("returns the exact fallback when Intl rejects an otherwise valid instant", () => {
  const fallback = "Keep this; exactly."

  assert.deepEqual(
    formatLocalTime("2026-08-28T12:30:00Z", "en-US", "Not/A_Time_Zone", fallback),
    {ok: false, text: fallback}
  )
})
