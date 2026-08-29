import test from "node:test"
import assert from "node:assert/strict"

import {createResponsiveModalFocusCoordinator} from "./responsive_modal_focus.mjs"

function harness(initialMobile) {
  const owners = []
  const coordinator = createResponsiveModalFocusCoordinator({
    activateDesktop: () => owners.push("desktop:on"),
    deactivateDesktop: () => owners.push("desktop:off")
  })
  coordinator.mount(initialMobile)
  return {coordinator, owners}
}

test("639 to 640 hands ownership from mobile to desktop exactly once", () => {
  const {coordinator, owners} = harness(true)
  assert.equal(coordinator.mode(), "mobile")
  coordinator.afterMobileDeactivate()
  assert.equal(coordinator.mode(), "desktop")
  assert.deepEqual(owners, ["desktop:on"])
})

test("640 to 639 tears down desktop before mobile activation", () => {
  const {coordinator, owners} = harness(false)
  coordinator.beforeMobileActivate()
  assert.equal(coordinator.mode(), "mobile")
  assert.deepEqual(owners, ["desktop:on", "desktop:off"])
})

test("repeated transitions and destroy are idempotent", () => {
  const {coordinator, owners} = harness(false)
  coordinator.beforeMobileActivate()
  coordinator.beforeMobileActivate()
  coordinator.afterMobileDeactivate()
  coordinator.afterMobileDeactivate()
  assert.equal(coordinator.destroy(), "desktop")
  assert.equal(coordinator.destroy(), "desktop")
  assert.deepEqual(owners, ["desktop:on", "desktop:off", "desktop:on", "desktop:off"])
})
