export function restoreModalFocus({document, previouslyFocused, previouslyFocusedId, fallbackReturnId} = {}) {
  const restoredTarget = previouslyFocused?.isConnected
    ? previouslyFocused
    : previouslyFocusedId && document?.getElementById?.(previouslyFocusedId)
  const focusTarget = restoredTarget || (fallbackReturnId && document?.getElementById?.(fallbackReturnId))
  focusTarget?.focus?.({preventScroll: true})
  return focusTarget || null
}

export function modalSheetReturnId(dialog) {
  return dialog?.closest?.("[data-sheet-return-id]")?.dataset?.sheetReturnId || null
}
