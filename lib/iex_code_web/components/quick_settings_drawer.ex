defmodule IexCodeWeb.Components.QuickSettingsDrawer do
  @moduledoc """
  Slide-over glass drawer component accessible from WorkspaceLive providing
  instant access to primary settings switches and deep-links to Settings Studio.
  """
  use Phoenix.Component
  use IexCodeWeb, :verified_routes
  import IexCodeWeb.CoreComponents, only: [icon: 1]

  attr :show, :boolean, default: false
  attr :settings, :any, required: true
  attr :session, :any, default: nil
  attr :class, :string, default: nil

  def quick_settings_drawer(assigns) do
    studio_path =
      if assigns.session do
        ~p"/sessions/#{assigns.session.id}/settings"
      else
        ~p"/settings"
      end

    assigns = assign(assigns, :studio_path, studio_path)

    ~H"""
    <div
      :if={@show}
      id="quick-settings-drawer-backdrop"
      class="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm transition-opacity"
      phx-click="toggle_quick_settings"
    >
      <aside
        id="quick-settings-drawer"
        onclick="event.stopPropagation();"
        class={[
          "fixed inset-y-0 right-0 z-50 flex w-full max-w-md flex-col border-l border-white/10 bg-[#0d1117]/95 backdrop-blur-2xl p-6 shadow-2xl font-sans text-gray-100 animate-in slide-in-from-right duration-200",
          @class
        ]}
      >
        <!-- Header -->
        <div class="flex items-center justify-between border-b border-white/10 pb-4">
          <div class="flex items-center gap-3">
            <div class="flex h-9 w-9 items-center justify-center rounded-xl bg-gradient-to-tr from-cyan-500 to-blue-600 text-white shadow-lg shadow-cyan-500/20">
              <.icon name="hero-adjustments-horizontal" class="h-5 w-5" />
            </div>
            <div>
              <h2 id="quick-settings-title" class="text-sm font-bold tracking-tight text-white">
                Quick Settings
              </h2>
              <p class="text-[11px] font-mono text-gray-400">
                Workspace runtime configuration
              </p>
            </div>
          </div>

          <button
            type="button"
            id="close-quick-settings-btn"
            phx-click="toggle_quick_settings"
            aria-label="Close quick settings"
            class="rounded-lg p-1.5 text-gray-400 hover:bg-white/10 hover:text-white transition-colors"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>

        <!-- Content Body -->
        <div class="flex-1 overflow-y-auto py-5 space-y-6">
          <!-- Default Model & Provider -->
          <div class="rounded-xl border border-white/5 bg-white/[0.02] p-4">
            <div class="flex items-center justify-between">
              <span class="text-xs font-semibold text-gray-300">Active Model</span>
              <span class="rounded-md border border-cyan-500/30 bg-cyan-500/10 px-2 py-0.5 font-mono text-[10px] text-cyan-300 uppercase">
                {@settings.default_model_provider}
              </span>
            </div>
            <p class="mt-1 font-mono text-sm font-semibold text-white truncate">
              {@settings.default_model}
            </p>
          </div>

          <!-- Reasoning Effort Fast Switch -->
          <div class="space-y-2">
            <label class="block text-xs font-semibold text-gray-300">
              Reasoning Effort
            </label>
            <div class="grid grid-cols-3 gap-2">
              <button
                :for={effort <- ~w(low medium high)}
                type="button"
                phx-click="quick_update_settings"
                phx-value-key="default_reasoning_effort"
                phx-value-value={effort}
                class={[
                  "rounded-lg border py-2 text-xs font-medium capitalize transition-all",
                  if(@settings.default_reasoning_effort == effort,
                    do:
                      "border-cyan-500 bg-cyan-500/20 text-white shadow-[0_0_12px_rgba(6,182,212,0.25)]",
                    else:
                      "border-white/10 bg-white/5 text-gray-400 hover:border-white/20 hover:text-white"
                  )
                ]}
              >
                {effort}
              </button>
            </div>
          </div>

          <!-- Tool Approval Mode Fast Switch -->
          <div class="space-y-2">
            <label class="block text-xs font-semibold text-gray-300">
              Tool Approval Mode
            </label>
            <div class="grid grid-cols-3 gap-2">
              <button
                :for={
                  {mode, label} <- [
                    {"full_auto", "Full Auto"},
                    {"prompt_dangerous", "Prompt"},
                    {"read_only", "Read Only"}
                  ]
                }
                type="button"
                phx-click="quick_update_settings"
                phx-value-key="tool_approval_mode"
                phx-value-value={mode}
                class={[
                  "rounded-lg border py-2 px-1 text-center text-xs font-medium transition-all",
                  if(@settings.tool_approval_mode == mode,
                    do:
                      "border-emerald-500 bg-emerald-500/20 text-white shadow-[0_0_12px_rgba(16,185,129,0.25)]",
                    else:
                      "border-white/10 bg-white/5 text-gray-400 hover:border-white/20 hover:text-white"
                  )
                ]}
              >
                {label}
              </button>
            </div>
          </div>

          <!-- Sound Effects Toggle -->
          <div class="flex items-center justify-between rounded-xl border border-white/5 bg-white/[0.02] p-4">
            <div>
              <span class="block text-xs font-semibold text-white">Desktop Audio</span>
              <span class="block text-[11px] text-gray-400">Chimes on completion and alerts</span>
            </div>
            <button
              type="button"
              id="drawer-sound-toggle-btn"
              phx-click="quick_update_settings"
              phx-value-key="sound_enabled"
              phx-value-value={to_string(!@settings.sound_enabled)}
              class={[
                "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none",
                if(@settings.sound_enabled, do: "bg-cyan-500", else: "bg-gray-700")
              ]}
            >
              <span class={[
                "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                if(@settings.sound_enabled, do: "translate-x-5", else: "translate-x-0")
              ]} />
            </button>
          </div>
        </div>

        <!-- Footer with Deep Link -->
        <div class="border-t border-white/10 pt-4">
          <.link
            id="drawer-open-full-studio-btn"
            navigate={@studio_path}
            class="flex w-full items-center justify-center gap-2 rounded-xl bg-gradient-to-r from-cyan-600 to-blue-600 px-4 py-2.5 text-xs font-semibold text-white shadow-lg shadow-cyan-500/20 transition-all hover:brightness-110 active:translate-y-px"
          >
            <span>Open Full Studio</span>
            <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
          </.link>
        </div>
      </aside>
    </div>
    """
  end
end
