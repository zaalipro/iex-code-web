export function updateConnectionStatus(document, connected, reason = "") {
  const status = document?.getElementById?.("connection-status")
  const indicator = document?.getElementById?.("mission-connection-indicator")
  const strip = document?.getElementById?.("mission-connection-status")
  const mark = document?.getElementById?.("mission-connection-mark")
  if (status) {
    status.hidden = connected
    status.textContent = connected ? "" : "Signal paused · reconnecting"
    status.dataset.state = connected ? "connected" : "reconnecting"
    status.dataset.reason = reason
  }
  if (strip) {
    strip.textContent = connected ? "Connected" : "Reconnecting"
    strip.dataset.state = connected ? "connected" : "reconnecting"
    strip.setAttribute?.("aria-label", connected ? "Connected" : "Reconnecting")
  }
  if (indicator) indicator.dataset.state = connected ? "connected" : "reconnecting"
  if (mark) {
    mark.dataset.state = connected ? "connected" : "reconnecting"
    mark.classList?.toggle?.("sf-success-mark", connected)
    mark.classList?.toggle?.("sf-live-mark", !connected)
  }
  document?.body?.classList?.toggle?.("phx-disconnected", !connected)
}
