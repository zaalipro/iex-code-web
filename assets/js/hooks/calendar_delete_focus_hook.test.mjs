import test from "node:test"
import assert from "node:assert/strict"

import CalendarDeleteFocus, {CalendarDeleteFocus as NamedCalendarDeleteFocus} from "./calendar_delete_focus_hook.js"

test("calendar delete focus lands only after acknowledged matching success", () => {
  let callback
  const focused = []
  const context = {
    el: {id: "calendar-heading", focus: options => focused.push(options)},
    handleEvent: (_event, handler) => { callback = handler; return {} }
  }
  CalendarDeleteFocus.mounted.call(context)
  callback({id: "forged"})
  assert.deepEqual(focused, [])
  callback({id: "calendar-heading"})
  assert.deepEqual(focused, [{preventScroll: true}])
})

test("named and default hook exports are identical", () => {
  assert.strictEqual(CalendarDeleteFocus, NamedCalendarDeleteFocus)
})
