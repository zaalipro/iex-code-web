defmodule IexCodeWeb.ThinkingTrace do
  @moduledoc """
  Expandable/collapsible reasoning trace disclosure component for LiveView.
  Displays LLM chain-of-thought with active pulsing indicator, token/byte badge,
  and formatted monospace pre/code block.
  """
  use Phoenix.Component
  import IexCodeWeb.CoreComponents

  @doc """
  Renders an expandable reasoning trace card.
  """
  attr :id, :string, default: nil
  attr :message_id, :any, default: nil
  attr :reasoning, :string, default: nil
  attr :active, :boolean, default: false
  attr :duration_ms, :any, default: nil
  attr :tokens, :any, default: nil

  def thinking_trace(assigns) do
    dom_id =
      cond do
        assigns.id -> assigns.id
        assigns.message_id -> "thinking-trace-#{assigns.message_id}"
        assigns.reasoning -> "thinking-trace-#{:erlang.phash2(assigns.reasoning)}"
        true -> "thinking-trace"
      end

    assigns = assign(assigns, :dom_id, dom_id)

    ~H"""
    <%= if @reasoning && String.trim(@reasoning) != "" do %>
      <details
        id={@dom_id}
        class="mb-3 rounded-2xl bg-[#161b22] border border-[#21262d] p-3 text-xs font-mono group transition-all shadow-inner"
      >
        <summary class="font-semibold text-amber-400 cursor-pointer flex items-center gap-2 select-none hover:text-amber-300 transition-colors">
          <div class="flex items-center gap-2">
            <%= if @active do %>
              <span class="relative flex h-2.5 w-2.5">
                <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-amber-400 opacity-75"></span>
                <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-amber-500"></span>
              </span>
            <% else %>
              <.icon name="hero-sparkles" class="w-3.5 h-3.5 text-amber-400 shrink-0" />
            <% end %>
            <span class="text-amber-300">Thought Process (Reasoning Trace)</span>
          </div>

          <div class="ml-auto flex items-center gap-2 text-[10px] font-mono text-gray-400">
            <%= if @duration_ms do %>
              <span class="px-1.5 py-0.5 rounded bg-white/5 border border-white/10 text-gray-300">
                {@duration_ms}ms
              </span>
            <% end %>
            <!-- Token/byte count badge -->
            <span class="px-1.5 py-0.5 rounded bg-white/5 border border-white/10 text-amber-400/90 font-medium">
              {metric_badge(@tokens, @reasoning)}
            </span>
            <.icon
              name="hero-chevron-down"
              class="w-3.5 h-3.5 text-gray-400 group-open:rotate-180 transition-transform"
            />
          </div>
        </summary>

        <div class="mt-2.5 pt-2.5 border-t border-[#21262d] text-[11px] text-gray-300 leading-relaxed font-mono overflow-x-auto max-h-96">
          <pre><code phx-no-curly-interpolation><%= @reasoning %></code></pre>
        </div>
      </details>
    <% end %>
    """
  end

  defp metric_badge(tokens, _reasoning) when is_integer(tokens) and tokens > 0,
    do: "#{tokens} tokens"

  defp metric_badge(tokens, _reasoning) when is_binary(tokens) and tokens != "",
    do: "#{tokens} tokens"

  defp metric_badge(_tokens, reasoning) when is_binary(reasoning) do
    bytes = byte_size(reasoning)
    approx_tokens = div(bytes, 4) + 1
    "~#{approx_tokens} tokens (#{bytes} B)"
  end

  defp metric_badge(_tokens, _reasoning), do: "Reasoning"
end
