const owners = new WeakMap()
const ownerStates = new WeakMap()
let latestOwnerRank = 0

// A later modal must be able to expose its own ancestor branch even when an
// older modal refreshes sibling isolation after the new branch is patched in.
function ownerState(owner) {
  if ((typeof owner !== "object" && typeof owner !== "function") || owner === null) return null
  let state = ownerStates.get(owner)
  if (!state) {
    state = {rank: ++latestOwnerRank, claims: 0}
    ownerStates.set(owner, state)
  }
  return state
}

function addClaim(ownerSet, owner) {
  if (ownerSet.has(owner)) return
  ownerSet.add(owner)
  const state = ownerState(owner)
  if (state) state.claims += 1
}

function removeClaim(ownerSet, owner) {
  if (!ownerSet.delete(owner)) return
  const state = ownerStates.get(owner)
  if (!state) return
  state.claims -= 1
  if (state.claims === 0) ownerStates.delete(owner)
}

function highestOwnerRank(ownerSet) {
  let rank = -1
  for (const owner of ownerSet) rank = Math.max(rank, ownerState(owner)?.rank || 0)
  return rank
}

function recordFor(target) {
  let record = owners.get(target)
  if (!record) {
    record = {
      owners: new Set(),
      exposures: new Set(),
      inert: Boolean(target.inert),
      hasAriaHidden: target.hasAttribute?.("aria-hidden") === true,
      ariaHidden: target.getAttribute?.("aria-hidden")
    }
    owners.set(target, record)
  }
  return record
}

function restore(target, record) {
  target.inert = record.inert
  if (record.hasAriaHidden) target.setAttribute?.("aria-hidden", record.ariaHidden ?? "")
  else target.removeAttribute?.("aria-hidden")
}

function apply(target, record) {
  const exposureRank = highestOwnerRank(record.exposures)
  const isolationRank = highestOwnerRank(record.owners)
  if (record.owners.size > 0 && isolationRank > exposureRank) {
    target.inert = true
    target.setAttribute?.("aria-hidden", "true")
  } else restore(target, record)

  if (record.owners.size === 0 && record.exposures.size === 0) owners.delete(target)
}

function acquire(target, owner) {
  if (!target || !owner) return null
  const record = recordFor(target)
  addClaim(record.owners, owner)
  apply(target, record)
  return record
}

function release(target, owner) {
  const record = target && owners.get(target)
  if (!record) return
  removeClaim(record.owners, owner)
  apply(target, record)
}

function expose(target, owner) {
  if (!target || !owner) return null
  const record = recordFor(target)
  addClaim(record.exposures, owner)
  apply(target, record)
  return record
}

function releaseExposure(target, owner) {
  const record = target && owners.get(target)
  if (!record) return
  removeClaim(record.exposures, owner)
  apply(target, record)
}

export function acquireModalIsolation(dialog, owner, {root = dialog?.ownerDocument?.body} = {}) {
  if (!dialog || !owner) return []
  const targets = []
  let branch = dialog
  let parent = dialog.parentElement
  while (parent) {
    for (const sibling of Array.from(parent.children || [])) {
      if (sibling === branch) continue
      acquire(sibling, owner)
      targets.push(sibling)
    }
    if (parent === root) break
    branch = parent
    parent = parent.parentElement
  }
  return targets
}

export function releaseModalIsolation(targets, owner) {
  for (const target of targets || []) release(target, owner)
}

export function acquireModalExposure(dialog, owner, {root = dialog?.ownerDocument?.body} = {}) {
  if (!dialog || !owner) return []
  const targets = []
  let branch = dialog
  while (branch && branch !== root) {
    expose(branch, owner)
    targets.push(branch)
    branch = branch.parentElement
  }
  return targets
}

export function releaseModalExposure(targets, owner) {
  for (const target of targets || []) releaseExposure(target, owner)
}

export function modalBackgroundId(dialog) {
  return dialog?.closest?.("[data-sheet-background-id]")?.dataset?.sheetBackgroundId || "workspace-shell"
}

export function acquireModalBackground(target, owner) {
  return acquire(target, owner)
}

export function releaseModalBackground(target, owner) {
  release(target, owner)
}

export function topmostUsableModal(dialogs = []) {
  return [...dialogs].reverse().find(dialog => {
    if (!dialog || dialog.inert) return false
    if (dialog.getAttribute?.("aria-hidden") === "true") return false
    let ancestor = dialog.parentElement
    while (ancestor) {
      if (ancestor.inert || ancestor.getAttribute?.("aria-hidden") === "true") return false
      ancestor = ancestor.parentElement
    }
    return typeof dialog.getClientRects !== "function" || dialog.getClientRects().length > 0
  }) || null
}
