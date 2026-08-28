const SURFACES = new Set([
  "kanban",
  "swarm",
  "research",
  "calendar",
  "changes",
  "chat",
  "files",
  "terminal"
])

const LAST_INSTRUMENT_PREFIX = "iexcode:last-instrument:"
const DECK_STATE_PREFIX = "iexcode:deck-state:"

const closedSurface = value => typeof value === "string" && SURFACES.has(value)
const cardId = surface => `instrument-card-${surface}`

const nonblank = value => typeof value === "string" && value.trim() !== ""

const visible = element => {
  if (!element || element.inert || element.disabled || element.hasAttribute?.("disabled")) return false
  if (element.getAttribute?.("aria-disabled") === "true") return false
  return typeof element.getClientRects !== "function" || element.getClientRects().length > 0
}

const validFocusedId = value => {
  if (value === null) return null
  if (typeof value !== "string") return null
  return SURFACES.has(value.replace(/^instrument-card-/, "")) && value === cardId(value.slice(16))
    ? value
    : null
}

const normalizedState = value => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  if (!Number.isFinite(value.capturedAt)) return null

  return {
    scrollTop: Number.isFinite(value.scrollTop) && value.scrollTop >= 0 ? value.scrollTop : 0,
    focusedInstrumentId: validFocusedId(value.focusedInstrumentId),
    capturedAt: value.capturedAt
  }
}

const storageGet = (storage, key) => {
  try {
    return storage?.getItem(key) ?? null
  } catch (_error) {
    return null
  }
}

const storageSet = (storage, key, value) => {
  try {
    storage?.setItem(key, value)
  } catch (_error) {
    // Storage may be denied or full. The deck remains fully usable without it.
  }
}

const storageRemove = (storage, key) => {
  try {
    storage?.removeItem(key)
  } catch (_error) {
    // A failed stale-state cleanup must not break the hook.
  }
}

const parsedSessionState = (storage, key) => {
  const raw = storageGet(storage, key)
  if (raw === null) return null

  try {
    return normalizedState(JSON.parse(raw))
  } catch (_error) {
    return null
  }
}

const safeHistoryState = history => {
  try {
    const state = history?.state
    return state && typeof state === "object" && !Array.isArray(state) ? state : {}
  } catch (_error) {
    return {}
  }
}

const replaceHistoryState = (history, location, deckState) => {
  try {
    history?.replaceState(
      {...safeHistoryState(history), iexcodeDeckState: deckState},
      "",
      location?.href
    )
  } catch (_error) {
    // Phoenix navigation still proceeds if browser history is unavailable.
  }
}

const historyDeckState = (value, storageKey) => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  if (value.storageKey !== storageKey) return null
  const state = normalizedState(value)
  return state ? {storageKey, ...state} : null
}

const destinationSurface = (to, location) => {
  if (typeof to !== "string" || !to) return null

  try {
    const base = new URL(location?.href || "http://localhost/")
    const url = new URL(to, base)
    if (url.origin !== base.origin || url.hash !== "") return null

    if (url.search === "" && url.pathname === "/research") return "research"
    if (url.search === "" && /^\/sessions\/[A-Za-z0-9._~-]+\/research$/.test(url.pathname)) {
      return "research"
    }

    if (!(url.pathname === "/" || /^\/sessions\/[A-Za-z0-9._~-]+$/.test(url.pathname))) {
      return null
    }

    const entries = [...url.searchParams.entries()]
    if (entries.length !== 1 || entries[0][0] !== "view") return null
    return closedSurface(entries[0][1]) && entries[0][1] !== "research" ? entries[0][1] : null
  } catch (_error) {
    return null
  }
}

const runtimeFor = (hook, provided) => {
  const globalWindow = typeof window === "undefined" ? null : window
  const globalDocument = typeof document === "undefined" ? null : document
  const win = provided.window || globalWindow

  return {
    window: win,
    document: provided.document || globalDocument,
    localStorage: provided.localStorage || (() => {
      try { return win?.localStorage } catch (_error) { return null }
    })(),
    sessionStorage: provided.sessionStorage || (() => {
      try { return win?.sessionStorage } catch (_error) { return null }
    })(),
    history: provided.history || (() => {
      try { return win?.history } catch (_error) { return null }
    })(),
    location: provided.location || (() => {
      try { return win?.location } catch (_error) { return null }
    })(),
    requestAnimationFrame: provided.requestAnimationFrame || win?.requestAnimationFrame?.bind(win),
    cancelAnimationFrame: provided.cancelAnimationFrame || win?.cancelAnimationFrame?.bind(win),
    now: provided.now || Date.now,
    pushEvent: provided.pushEvent || hook.pushEvent?.bind(hook)
  }
}

export const createInstrumentDeckHook = (provided = {}) => ({
  mounted() {
    this.runtime = runtimeFor(this, provided)
    this.lastInstrumentKey = null
    this.deckStateKey = null
    this.activeView = this.el?.dataset?.activeView || null
    this.resumePushedForKey = null
    this.previousDeckStateKey = null
    this.pendingPopState = null
    this.popRestorePending = false
    this.restoreFrame = null

    this.handleClick = event => this.captureClick(event)
    this.handlePageLoadingStart = event => this.capturePageLoading(event)
    this.handlePopState = event => this.capturePopState(event)

    this.el?.addEventListener?.("click", this.handleClick, true)
    this.runtime.window?.addEventListener?.("phx:page-loading-start", this.handlePageLoadingStart)
    this.runtime.window?.addEventListener?.("popstate", this.handlePopState)

    this.syncContext()
    this.hydrateResume()
    if (this.activeView === "deck") this.scheduleRestore()
  },

  updated() {
    const previousView = this.activeView
    const nextView = this.el?.dataset?.activeView || null
    const contextChanged = this.syncContext()
    this.activeView = nextView
    this.hydrateResume()

    if (this.popRestorePending && nextView !== "deck") {
      this.pendingPopState = null
      this.popRestorePending = false
    }

    if (
      nextView === "deck" &&
      (contextChanged || previousView !== "deck" || this.popRestorePending)
    ) {
      this.scheduleRestore()
    }
  },

  destroyed() {
    this.el?.removeEventListener?.("click", this.handleClick, true)
    this.runtime?.window?.removeEventListener?.(
      "phx:page-loading-start",
      this.handlePageLoadingStart
    )
    this.runtime?.window?.removeEventListener?.("popstate", this.handlePopState)
    if (this.restoreFrame !== null) {
      this.runtime?.cancelAnimationFrame?.(this.restoreFrame)
      this.restoreFrame = null
    }
  },

  syncContext() {
    const projectId = this.el?.dataset?.projectId
    const sessionId = this.el?.dataset?.sessionId
    if (!nonblank(projectId) || !nonblank(sessionId)) {
      if (this.deckStateKey !== null) this.previousDeckStateKey = this.deckStateKey
      this.lastInstrumentKey = null
      this.deckStateKey = null
      this.resumePushedForKey = null
      this.pendingPopState = null
      this.popRestorePending = false
      return false
    }

    const lastInstrumentKey = `${LAST_INSTRUMENT_PREFIX}${projectId}:${sessionId}`
    const deckStateKey = `${DECK_STATE_PREFIX}${projectId}:${sessionId}`
    if (deckStateKey === this.deckStateKey) return false

    if (this.deckStateKey !== null) this.previousDeckStateKey = this.deckStateKey
    this.lastInstrumentKey = lastInstrumentKey
    this.deckStateKey = deckStateKey
    this.resumePushedForKey = null
    return true
  },

  hydrateResume() {
    if (!this.lastInstrumentKey || this.resumePushedForKey === this.lastInstrumentKey) return
    this.resumePushedForKey = this.lastInstrumentKey
    const surface = storageGet(this.runtime.localStorage, this.lastInstrumentKey)
    if (closedSurface(surface)) this.runtime.pushEvent?.("restore_last_instrument", {surface})
  },

  deckScroller() {
    return this.el?.querySelector?.("#instrument-deck") || null
  },

  captureState(focusedInstrumentId, scrollTop) {
    if (!this.deckStateKey) return
    const sessionValue = {
      scrollTop: Number.isFinite(scrollTop) && scrollTop >= 0 ? scrollTop : 0,
      focusedInstrumentId: validFocusedId(focusedInstrumentId),
      capturedAt: this.runtime.now()
    }
    if (!Number.isFinite(sessionValue.capturedAt)) return

    storageSet(this.runtime.sessionStorage, this.deckStateKey, JSON.stringify(sessionValue))
    replaceHistoryState(this.runtime.history, this.runtime.location, {
      storageKey: this.deckStateKey,
      ...sessionValue
    })
  },

  captureClick(event) {
    const target = event?.target
    const card = target?.closest?.("[data-instrument-surface]")

    if (card && this.el?.contains?.(card)) {
      const surface = card.dataset?.instrumentSurface
      if (
        this.lastInstrumentKey &&
        closedSurface(surface) &&
        card.id === cardId(surface) &&
        visible(card) &&
        this.activeView === "deck"
      ) {
        storageSet(this.runtime.localStorage, this.lastInstrumentKey, surface)
        this.captureState(card.id, this.deckScroller()?.scrollTop)
        this.runtime.pushEvent?.("restore_last_instrument", {surface})
      }
      return
    }

    const returnControl = target?.closest?.('[id^="return-to-instrument-deck-"]')
    const surface = this.el?.dataset?.activeView
    if (!this.deckStateKey || !returnControl || !this.el?.contains?.(returnControl) || !visible(returnControl)) return
    if (!closedSurface(surface)) return

    const previous = parsedSessionState(this.runtime.sessionStorage, this.deckStateKey)
    this.captureState(cardId(surface), previous?.scrollTop ?? 0)
  },

  capturePageLoading(event) {
    if (this.el?.dataset?.activeView !== "deck" || !this.deckStateKey) return
    const scroller = this.deckScroller()
    const active = this.runtime.document?.activeElement
    const focusedCard = active?.closest?.("[data-instrument-surface]")
    const focusedSurface = focusedCard?.dataset?.instrumentSurface
    const focusedId =
      focusedCard &&
      this.el?.contains?.(focusedCard) &&
      closedSurface(focusedSurface) &&
      focusedCard.id === cardId(focusedSurface) &&
      visible(focusedCard)
        ? focusedCard.id
        : parsedSessionState(this.runtime.sessionStorage, this.deckStateKey)?.focusedInstrumentId

    this.captureState(focusedId || null, scroller?.scrollTop)

    const surface = destinationSurface(event?.detail?.to, this.runtime.location)
    if (surface) {
      storageSet(this.runtime.localStorage, this.lastInstrumentKey, surface)
      this.runtime.pushEvent?.("restore_last_instrument", {surface})
    }
  },

  capturePopState(event) {
    this.pendingPopState = event?.state?.iexcodeDeckState ?? null
    this.popRestorePending = true
  },

  scheduleRestore() {
    if (this.restoreFrame !== null) this.runtime.cancelAnimationFrame?.(this.restoreFrame)
    if (typeof this.runtime.requestAnimationFrame !== "function") return

    this.restoreFrame = this.runtime.requestAnimationFrame(() => {
      this.restoreFrame = null
      this.restoreDeck()
    })
  },

  restoreDeck() {
    const scroller = this.deckScroller()
    if (!scroller) return false

    const saved =
      (this.popRestorePending && historyDeckState(this.pendingPopState, this.deckStateKey)) ||
      parsedSessionState(this.runtime.sessionStorage, this.deckStateKey) ||
      {scrollTop: 0, focusedInstrumentId: null, capturedAt: 0}

    scroller.scrollTop = saved.scrollTop

    let focusTarget = null
    if (saved.focusedInstrumentId) {
      const candidate = this.el?.querySelector?.(`#${saved.focusedInstrumentId}`)
      if (visible(candidate)) focusTarget = candidate
    }
    focusTarget ||= this.el?.querySelector?.("#instrument-deck-heading")
    if (!visible(focusTarget)) focusTarget = scroller
    focusTarget?.focus?.({preventScroll: true})

    this.pendingPopState = null
    this.popRestorePending = false
    if (
      this.deckStateKey &&
      this.previousDeckStateKey &&
      this.previousDeckStateKey !== this.deckStateKey
    ) {
      storageRemove(this.runtime.sessionStorage, this.previousDeckStateKey)
      this.previousDeckStateKey = null
    }
    return true
  }
})

export const InstrumentDeck = createInstrumentDeckHook()
export default InstrumentDeck
