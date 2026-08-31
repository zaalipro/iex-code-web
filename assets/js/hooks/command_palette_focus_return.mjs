export function resolveCommandPaletteFocusTarget({document, previouslyFocused} = {}) {
  if (previouslyFocused?.isConnected) return previouslyFocused
  return document?.getElementById?.("command-palette-trigger") || null
}
