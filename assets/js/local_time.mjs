export function formatLocalTime(iso, locale, timeZone, fallbackText) {
  try {
    if (typeof iso !== "string" || iso.trim() === "") {
      return {ok: false, text: fallbackText}
    }

    const date = new Date(iso)
    if (Number.isNaN(date.getTime())) return {ok: false, text: fallbackText}

    return {
      ok: true,
      text: new Intl.DateTimeFormat(locale, {
        dateStyle: "medium",
        timeStyle: "short",
        timeZone
      }).format(date)
    }
  } catch (_error) {
    return {ok: false, text: fallbackText}
  }
}
