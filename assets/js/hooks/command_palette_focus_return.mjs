export function resolveCommandPaletteFocusTarget({document, previouslyFocused} = {}) {
  if (previouslyFocused?.isConnected) return previouslyFocused
  return document?.getElementById?.("command-palette-trigger") || null
}

export function commandPaletteShouldRestoreFocus({document, previouslyFocused, openingModal} = {}) {
  const modals = Array.from(document?.querySelectorAll?.("[data-modal-focus]") || [])
    .filter(modal => modal?.isConnected !== false && modal?.inert !== true)
  const replacementModal = modals.some(modal => modal !== openingModal)
  if (replacementModal) return false
  if (openingModal && openingModal.isConnected !== false) {
    return previouslyFocused?.isConnected === true && openingModal.contains?.(previouslyFocused) === true
  }
  return modals.length === 0
}
