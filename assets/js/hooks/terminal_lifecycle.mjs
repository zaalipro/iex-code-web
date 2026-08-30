export function initialTerminalLifecycle(active) {
  return { isActive: active === true, historyNeeded: active !== true }
}

export function transitionTerminalLifecycle(state, nextSessionId, nextActive) {
  const active = nextActive === true
  const sessionChanged = nextSessionId !== state.sessionId
  const becameActive = active && !state.isActive
  let historyNeeded = state.historyNeeded || sessionChanged
  const requestHistory = active && historyNeeded && (sessionChanged || becameActive)

  if (requestHistory) historyNeeded = false

  return {
    state: { sessionId: nextSessionId, isActive: active, historyNeeded },
    reset: sessionChanged,
    requestHistory,
    focus: becameActive
  }
}
