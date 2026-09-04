defmodule IexCodeWeb.ToolApprovalModal do
  @moduledoc """
  Visual tool execution approval modal component for LiveView.
  Presents safety tier, category, tool details, parameters/command preview,
  risk explanation, and 3 action choices: Approve Once, Always Allow for Session, and Deny.
  """
  use Phoenix.Component
  import IexCodeWeb.CoreComponents

  @doc """
  Renders the interactive tool approval modal.
  """
  attr :request, :map, default: nil
  attr :id, :string, default: "tool-approval-modal"

  def tool_approval_modal(assigns) do
    ~H"""
    <div
      :if={@request}
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm p-4 animate-fade-in"
      role="dialog"
      aria-modal="true"
      aria-labelledby="tool-approval-title"
    >
      <div class="relative w-full max-w-2xl overflow-hidden rounded-2xl border border-amber-500/30 bg-[#0d1117] shadow-2xl shadow-black/90 ring-1 ring-white/10">
        <!-- Header -->
        <div class="flex items-center justify-between border-b border-white/10 px-6 py-4 bg-[#161b22]">
          <div class="flex items-center gap-3">
            <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-amber-500/10 border border-amber-500/20 text-amber-400">
              <.icon name="hero-shield-exclamation" class="h-6 w-6" />
            </div>
            <div>
              <h3 id="tool-approval-title" class="text-sm font-semibold text-white">
                Tool Execution Approval Required
              </h3>
              <p class="text-xs text-gray-400">
                An autonomous agent is requesting permission to execute a potentially risky tool
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <!-- Safety Tier Badge -->
            <span
              id="tool-approval-tier-badge"
              class="inline-flex items-center rounded-md bg-amber-400/10 px-2.5 py-1 text-[11px] font-mono font-medium text-amber-400 ring-1 ring-inset ring-amber-400/20"
            >
              Tier: {request_field(@request, :tier) || "prompt_dangerous"}
            </span>
            <!-- Category Badge -->
            <span
              id="tool-approval-category-badge"
              class="inline-flex items-center rounded-md bg-purple-400/10 px-2.5 py-1 text-[11px] font-mono font-medium text-purple-300 ring-1 ring-inset ring-purple-400/20"
            >
              {request_field(@request, :category) || "mutating"}
            </span>
          </div>
        </div>

        <!-- Body -->
        <div class="space-y-4 px-6 py-5">
          <!-- Tool Name & Risk Reason -->
          <div class="rounded-xl bg-white/[0.03] border border-white/5 p-4 space-y-2.5">
            <div class="flex items-center justify-between text-xs">
              <span class="text-gray-400 font-medium">Requested Tool:</span>
              <span
                id="tool-approval-name"
                class="font-mono font-bold text-cyan-400 bg-cyan-950/40 px-2.5 py-1 rounded border border-cyan-800/40"
              >
                {request_field(@request, :tool_name) || "unknown_tool"}
              </span>
            </div>
            <div class="text-xs text-gray-300">
              <span class="text-gray-400 font-medium">Risk Justification:</span>
              <p id="tool-approval-reason" class="mt-1 text-amber-200/90 font-sans leading-relaxed">
                {request_field(@request, :reason) ||
                  "Tool modifies files or executes commands in the workspace"}
              </p>
            </div>
          </div>

          <!-- Parameters / Command / Diff Preview -->
          <div>
            <div class="flex items-center justify-between text-xs text-gray-400 font-medium mb-1.5">
              <span>Tool Parameters / Command Preview</span>
              <span class="text-[10px] font-mono text-gray-500">
                ID: {request_field(@request, :id)}
              </span>
            </div>
            <div
              id="tool-approval-preview-box"
              class="rounded-xl border border-white/10 bg-[#090d13] p-3 text-xs font-mono text-gray-300 overflow-x-auto max-h-60"
            >
              <pre><code phx-no-curly-interpolation><%= format_preview(preview_content(@request)) %></code></pre>
            </div>
          </div>
        </div>

        <!-- Action Buttons -->
        <div class="flex items-center justify-between border-t border-white/10 px-6 py-4 bg-[#161b22]">
          <!-- Deny Button -->
          <button
            id="deny-tool-btn"
            type="button"
            phx-click="deny_tool"
            phx-value-id={request_field(@request, :id)}
            class="inline-flex items-center gap-2 rounded-xl bg-red-500/10 border border-red-500/30 px-4 py-2.5 text-xs font-medium text-red-400 hover:bg-red-500/20 hover:text-red-300 transition-colors"
          >
            <.icon name="hero-x-mark" class="h-4 w-4" /> Deny
          </button>

          <div class="flex items-center gap-3">
            <!-- Allow for Session Button -->
            <button
              id="allow-tool-session-btn"
              type="button"
              phx-click="allow_tool_session"
              phx-value-id={request_field(@request, :id)}
              class="inline-flex items-center gap-2 rounded-xl bg-purple-500/10 border border-purple-500/30 px-4 py-2.5 text-xs font-medium text-purple-300 hover:bg-purple-500/20 hover:text-purple-200 transition-colors"
            >
              <.icon name="hero-check-badge" class="h-4 w-4" /> Allow for Session
            </button>

            <!-- Approve Once Button -->
            <button
              id="approve-tool-once-btn"
              type="button"
              phx-click="approve_tool_once"
              phx-value-id={request_field(@request, :id)}
              class="inline-flex items-center gap-2 rounded-xl bg-emerald-600 hover:bg-emerald-500 px-4 py-2.5 text-xs font-medium text-white shadow-lg shadow-emerald-900/30 transition-colors"
            >
              <.icon name="hero-check" class="h-4 w-4" /> Approve Once
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp request_field(req, key) when is_map(req) and is_atom(key) do
    Map.get(req, key) || Map.get(req, Atom.to_string(key))
  end

  defp request_field(_req, _key), do: nil

  defp preview_content(req) when is_map(req) do
    request_field(req, :arguments) ||
      request_field(req, :command) ||
      request_field(req, :diff) ||
      request_field(req, :params) ||
      %{}
  end

  defp preview_content(_), do: "{}"

  defp format_preview(content) when is_binary(content), do: content

  defp format_preview(content) when is_map(content) or is_list(content) do
    case Jason.encode(content, pretty: true) do
      {:ok, pretty} -> pretty
      _ -> inspect(content, pretty: true)
    end
  end

  defp format_preview(other), do: inspect(other, pretty: true)
end
