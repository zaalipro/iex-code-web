const DARK = "dark"
const LIGHT = "light"
const SYSTEM = "system"
const DARK_THEME_COLOR = "#171514"
const LIGHT_THEME_COLOR = "#EAE5DC"
const THEME_COOKIE = "iexcode_theme"
const THEME_STORAGE_KEY = "phx:theme"
const SYSTEM_QUERY = "(prefers-color-scheme: dark)"

const explicitTheme = theme => theme === DARK || theme === LIGHT
const themeColor = theme => theme === DARK ? DARK_THEME_COLOR : LIGHT_THEME_COLOR
const secureCookie = env => env.window.location.protocol === "https:"

function mediaQuery(env) {
  const matchMedia = env.matchMedia || env.window.matchMedia.bind(env.window)
  return matchMedia(SYSTEM_QUERY)
}

function themeColorMetas(document) {
  return document.querySelectorAll('meta[name="theme-color"]')
}

function updateExplicitThemeColor(theme, document) {
  const content = themeColor(theme)
  themeColorMetas(document).forEach(meta => { meta.content = content })
}

function updateSystemThemeColor(resolvedTheme, document) {
  themeColorMetas(document).forEach(meta => {
    if (meta.media === "(prefers-color-scheme: dark)") {
      meta.content = DARK_THEME_COLOR
    } else if (meta.media === "(prefers-color-scheme: light)") {
      meta.content = LIGHT_THEME_COLOR
    } else {
      meta.content = themeColor(resolvedTheme)
    }
  })
}

function dispatchThemeChanged(theme, env) {
  env.window.dispatchEvent(new env.window.CustomEvent("iexcode:theme-changed", {
    detail: {theme}
  }))
}

export function resolveTheme({explicitTheme: preference, prefersDark}) {
  return explicitTheme(preference) ? preference : prefersDark ? DARK : LIGHT
}

export function themeCookie(theme, {secure}) {
  const suffix = secure === true ? "; Secure" : ""
  return `${THEME_COOKIE}=${theme}; Path=/; Max-Age=31536000; SameSite=Strict${suffix}`
}

export function expiredThemeCookie({secure}) {
  const suffix = secure === true ? "; Secure" : ""
  return `${THEME_COOKIE}=; Path=/; Max-Age=0; SameSite=Strict${suffix}`
}

export function applyTheme(theme, env) {
  if (!explicitTheme(theme)) return

  const root = env.document.documentElement
  root.dataset.theme = theme
  delete root.dataset.themeSource
  root.style.colorScheme = theme
  env.document.cookie = themeCookie(theme, {secure: secureCookie(env)})
  env.localStorage.setItem(THEME_STORAGE_KEY, theme)
  updateExplicitThemeColor(theme, env.document)
  dispatchThemeChanged(theme, env)
}

export function setSystemTheme(env) {
  const root = env.document.documentElement
  root.removeAttribute("data-theme")
  delete root.dataset.themeSource
  root.style.colorScheme = "light dark"
  env.localStorage.removeItem(THEME_STORAGE_KEY)
  env.document.cookie = expiredThemeCookie({secure: secureCookie(env)})

  const theme = resolveTheme({prefersDark: mediaQuery(env).matches})
  updateSystemThemeColor(theme, env.document)
  dispatchThemeChanged(theme, env)
}

export function setTheme(theme, env) {
  if (theme === SYSTEM) return setSystemTheme(env)
  if (explicitTheme(theme)) return applyTheme(theme, env)
}
