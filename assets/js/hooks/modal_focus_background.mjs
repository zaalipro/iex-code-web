const owners = new WeakMap()

function acquire(target, owner) {
  if (!target || !owner) return null
  let record = owners.get(target)
  if (!record) {
    record = {
      owners: new Set(),
      inert: Boolean(target.inert),
      hasAriaHidden: target.hasAttribute?.("aria-hidden") === true,
      ariaHidden: target.getAttribute?.("aria-hidden")
    }
    owners.set(target, record)
  }
  record.owners.add(owner)
  target.inert = true
  target.setAttribute?.("aria-hidden", "true")
  return record
}

function release(target, owner) {
  const record = target && owners.get(target)
  if (!record) return
  record.owners.delete(owner)
  if (record.owners.size > 0) return
  target.inert = record.inert
  if (record.hasAriaHidden) target.setAttribute?.("aria-hidden", record.ariaHidden ?? "")
  else target.removeAttribute?.("aria-hidden")
  owners.delete(target)
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
