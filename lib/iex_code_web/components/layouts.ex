defmodule IexCodeWeb.Layouts do
  @moduledoc """
  Layouts for the self-hosted IexCode Web coding harness.
  """
  use IexCodeWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the web application layout.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the current scope"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen w-full bg-[#0d1117] text-[#f0f6fc] font-sans antialiased overflow-hidden flex flex-col">
      {render_slot(@inner_block)}
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc "Renders a CSRF-protected administrator sign-out control."
  attr :id, :string, required: true
  attr :class, :string, default: nil

  def logout_button(assigns) do
    assigns = assign(assigns, :logout_form, to_form(%{}, as: :logout))

    ~H"""
    <.form for={@logout_form} id={@id} action={~p"/logout"} method="post" class={@class}>
      <button
        id={"#{@id}-button"}
        type="submit"
        class="sf-control inline-flex min-h-11 items-center gap-2 rounded-xl px-3 text-xs font-medium text-[var(--sf-text-secondary)] transition-colors hover:text-[var(--sf-text-primary)] active:translate-y-px"
      >
        <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
        <span>Sign out</span>
      </button>
    </.form>
    """
  end

  @doc """
  Shows flash messages.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="fixed bottom-4 right-4 z-50 flex flex-col gap-2 max-w-sm">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
