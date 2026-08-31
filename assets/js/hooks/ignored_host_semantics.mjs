export function syncTerminalAriaDisabled(element) {
  if (!element?.setAttribute) return
  element.setAttribute("aria-disabled", element.dataset?.inputLocked === "true" ? "true" : "false")
}

export function syncCopyLabel(element) {
  const label = element?.dataset?.copyLabel
  if (label && element.setAttribute) element.setAttribute("aria-label", label)
}

export function syncLocalTime(element) {
  const utc = element?.dataset?.utc
  if (utc && element.setAttribute) element.setAttribute("datetime", utc)
}
