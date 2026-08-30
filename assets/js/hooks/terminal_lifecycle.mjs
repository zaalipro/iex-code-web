export function initialTerminalLifecycle(active) {
  return { isActive: active === true, historyNeeded: true }
}

export function consumeInitialHandshake(
  state,
  scheduledSessionId,
  currentSessionId,
  scheduledGeneration = 0,
  currentGeneration = 0,
  active
) {
  const valid =
    scheduledSessionId === currentSessionId &&
      scheduledGeneration === currentGeneration &&
      active === true &&
      state.historyNeeded
  return {
    state: valid ? {...state, historyNeeded: false} : state,
    requestHistory: valid,
    focus: valid
  }
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
