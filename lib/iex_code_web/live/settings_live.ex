defmodule IexCodeWeb.SettingsLive do
  @moduledoc """
  Global application defaults, credentials, and operational preferences.

  The page intentionally keeps global defaults separate from session-specific
  state. A session route supplies context and a return destination only; saving
  still updates the singleton application settings record.
  """
  use IexCodeWeb, :live_view

  alias Ecto.Changeset
  alias IexCode.{Sessions, Settings}
  alias IexCode.Observability.RuntimeStatus
  alias IexCode.Research.Registry, as: SearchRegistry

  @runtime_refresh_interval 5_000

  @settings_sections [
    {"models", "Models"},
    {"execution", "Execution"},
    {"goals", "Goals"},
    {"swarm", "Swarm"},
    {"research", "Research"},
    {"providers", "Providers"},
    {"editor", "Editor"},
    {"usage", "Usage"},
    {"runtime", "Runtime"}
  ]

  @impl true
  def mount(params, _session, socket) do
    settings = Settings.get_settings()
    context_session = load_context_session(params["id"])
    invalid_session_context? = is_binary(params["id"]) and is_nil(context_session)

    if connected?(socket) and function_exported?(Settings, :subscribe, 0) do
      apply(Settings, :subscribe, [])
    end

    {usage_status, usage_rows, usage_totals, usage_message} = load_usage(context_session)

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:settings, settings)
      |> assign(:settings_form, settings_form(settings))
      |> assign(:settings_status, :idle)
      |> assign(:settings_message, "All changes are saved locally on this machine.")
      |> assign(:saved_at, nil)
      |> assign(:external_update?, false)
      |> assign(:context_session, context_session)
      |> assign(:invalid_session_context?, invalid_session_context?)
      |> assign(:return_path, return_path(context_session))
      |> assign(:search_provider_descriptors, ordered_descriptors(settings))
      |> assign(:provider_filter, "")
      |> assign(:expanded_providers, MapSet.new())
      |> assign(:usage_status, usage_status)
      |> assign(:usage_rows, usage_rows)
      |> assign(:usage_totals, usage_totals)
      |> assign(:usage_message, usage_message)
      |> assign(:runtime_status, load_runtime_status())

    if connected?(socket), do: schedule_runtime_refresh()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_settings", %{"settings" => params}, socket) do
    changeset = draft_changeset(socket.assigns.settings, params)

    {:noreply,
     socket
     |> assign(:settings_form, to_form(changeset, as: :settings))
     |> assign(:settings_status, :dirty)
     |> assign(:settings_message, "Unsaved changes")}
  end

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    case update_from_form(socket.assigns.settings, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_saved(updated, "Settings saved")
         |> put_flash(:info, "Settings saved")}

      {:error, %Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:settings_form, to_form(%{changeset | action: :validate}, as: :settings))
         |> assign(:settings_status, :error)
         |> assign(:settings_message, "Review the highlighted fields and try again.")}

      {:error, {:db_error, reason}} ->
        {:noreply, assign_save_error(socket, database_error(reason), params)}

      {:error, :stale_settings} ->
        {:noreply,
         socket
         |> assign_save_error(
           "Settings changed in another window. Discard to load the saved version, then apply your edit again.",
           params
         )
         |> assign(:external_update?, true)}

      {:error, reason} ->
        {:noreply, assign_save_error(socket, save_error(reason), params)}
    end
  end

  @impl true
  def handle_event("discard_settings", _params, socket) do
    settings = Settings.get_settings()

    {:noreply,
     socket
     |> assign(:settings, settings)
     |> assign(:settings_form, settings_form(settings))
     |> assign(:search_provider_descriptors, ordered_descriptors(settings))
     |> assign(:settings_status, :idle)
     |> assign(:settings_message, "Changes discarded. Showing saved settings.")
     |> assign(:saved_at, nil)
     |> assign(:external_update?, false)
     |> push_event("settings_clear_secrets", %{})}
  end

  @impl true
  def handle_event("clear_credential", %{"credential" => credential}, socket) do
    draft_params = form_params(socket.assigns.settings_form)

    with {:ok, credential_key} <- credential_key(credential),
         true <- function_exported?(Settings, :clear_credential, 2),
         {:ok, updated} <-
           apply(Settings, :clear_credential, [socket.assigns.settings, credential_key]) do
      {:noreply,
       socket
       |> assign_cleared_credential(updated, draft_params, credential_key)
       |> put_flash(:info, "Credential removed")}
    else
      false ->
        {:noreply,
         socket
         |> assign(:settings_status, :error)
         |> assign(:settings_message, "Credential removal is unavailable in this build.")}

      {:error, :stale_settings} ->
        {:noreply,
         socket
         |> assign_save_error(
           "Settings changed in another window. Discard to load the saved version before removing this credential.",
           draft_params
         )
         |> assign(:external_update?, true)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:settings_status, :error)
         |> assign(:settings_message, save_error(reason))}
    end
  end

  @impl true
  def handle_event("toggle_provider_advanced", %{"provider" => provider}, socket) do
    known? = Enum.any?(socket.assigns.search_provider_descriptors, &(provider_id(&1) == provider))

    expanded =
      if known? do
        toggle_set_member(socket.assigns.expanded_providers, provider)
      else
        socket.assigns.expanded_providers
      end

    {:noreply, assign(socket, :expanded_providers, expanded)}
  end

  @impl true
  def handle_event("filter_providers", params, socket) when is_map(params) do
    value = Map.get(params, "value", Map.get(params, "provider_filter", ""))
    {:noreply, assign(socket, :provider_filter, value |> to_string() |> String.slice(0, 80))}
  end

  @impl true
  def handle_event("move_provider", %{"provider" => provider, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    order = provider_order(socket.assigns.settings_form, socket.assigns.settings)

    if provider in order do
      new_order = move_in_order(order, provider, direction)

      draft_params =
        socket.assigns.settings_form
        |> form_params()
        |> Map.put("search_provider_order", new_order)

      {:noreply, assign_reordered_draft(socket, draft_params, new_order)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_provider", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:settings_updated, updated}, socket) do
    cond do
      same_settings_version?(socket.assigns.settings, updated) ->
        # The subscriber also receives its own successful write. Preserve the
        # more specific local status message (for example, provider order).
        {:noreply, socket}

      socket.assigns.settings_status in [:dirty, :error] ->
        {:noreply, assign(socket, :external_update?, true)}

      true ->
        {:noreply, assign_saved(socket, updated, "Settings updated")}
    end
  end

  def handle_info(:refresh_runtime_status, socket) do
    schedule_runtime_refresh()
    {:noreply, assign(socket, :runtime_status, load_runtime_status())}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def provider_id(descriptor), do: descriptor.id |> Atom.to_string()

  def settings_sections, do: @settings_sections

  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :tone, :string, default: "default"

  def settings_section_header(assigns) do
    ~H"""
    <header class="mb-6 border-b border-[#29313a] pb-5">
      <p class={[
        "font-mono text-[11px] font-semibold uppercase tracking-[0.16em]",
        if(@tone == "research", do: "text-violet-300", else: "text-[#ff8a68]")
      ]}>
        {@eyebrow}
      </p>
      <h2 id={@id} class="mt-2 text-xl font-semibold tracking-[-0.02em] text-white sm:text-2xl">
        {@title}
      </h2>
      <p class="mt-2 max-w-[68ch] text-sm leading-6 text-gray-400">{@description}</p>
    </header>
    """
  end

  attr :configured, :boolean, required: true

  def credential_badge(assigns) do
    ~H"""
    <span class={[
      "shrink-0 border px-2 py-1 font-mono text-[11px] font-semibold uppercase tracking-wider",
      if(@configured,
        do: "border-emerald-400/25 bg-emerald-400/[0.06] text-emerald-300",
        else: "border-[#3a424c] bg-[#0b0f14] text-gray-500"
      )
    ]}>
      {if @configured, do: "Configured", else: "Not configured"}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :checked, :boolean, default: false

  def tool_checkbox(assigns) do
    ~H"""
    <label for={@id} class="settings-tool-choice">
      <input type="hidden" name={@name} value="false" />
      <input
        id={@id}
        type="checkbox"
        name={@name}
        value="true"
        checked={@checked}
        class="mt-0.5 h-4 w-4 shrink-0 accent-[#ff8a68]"
      />
      <span>
        <span class="block text-sm font-semibold text-gray-200">{@label}</span>
        <span class="mt-1 block text-xs leading-5 text-gray-500">{@description}</span>
      </span>
    </label>
    """
  end

  def provider_name(descriptor) do
    descriptor.id
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def provider_config(form, settings, provider) do
    form_params = form_params(form)

    saved =
      settings.search_providers
      |> Kernel.||(%{})
      |> Map.get(provider, %{})
      |> normalize_provider_config()

    submitted =
      form_params
      |> Map.get("search_providers", %{})
      |> Map.get(provider)

    if is_map(submitted) do
      submitted
      |> normalize_provider_config()
      |> Enum.reject(fn
        {"api_key", value} when is_binary(value) -> String.trim(value) == ""
        _entry -> false
      end)
      |> Map.new()
      |> then(&Map.merge(saved, &1))
    else
      saved
    end
  end

  def provider_enabled?(config),
    do: Map.get(config, "enabled", Map.get(config, :enabled, false)) in [true, "true", "1", "on"]

  def credential_configured?(value), do: is_binary(value) and String.trim(value) != ""

  def credential_placeholder(value) do
    if credential_configured?(value),
      do: "Saved credential · enter a replacement",
      else: "Enter credential"
  end

  def tool_enabled?(form, settings, tool) do
    form_value =
      form
      |> form_params()
      |> Map.get("default_tools", %{})
      |> Map.get(tool)

    if is_nil(form_value) do
      settings.default_tools
      |> Kernel.||(%{})
      |> Map.get(tool, false)
    else
      form_value in [true, "true", "1", "on"]
    end
  end

  def provider_ready?(descriptor, config) do
    key_ready? =
      :api_key not in descriptor.config_fields or credential_configured?(config["api_key"])

    instance_ready? =
      descriptor.id != :searxng or credential_configured?(config["base_url"])

    engine_ready? =
      descriptor.id != :google or credential_configured?(config["engine_id"])

    descriptor.lifecycle != :retired and key_ready? and instance_ready? and engine_ready?
  end

  def provider_status(descriptor, config) do
    cond do
      descriptor.lifecycle == :retired -> {"Retired", "retired"}
      provider_ready?(descriptor, config) and provider_enabled?(config) -> {"Enabled", "enabled"}
      provider_ready?(descriptor, config) -> {"Configured", "configured"}
      true -> {"Needs setup", "missing"}
    end
  end

  def provider_lifecycle_note(%{lifecycle: :sunsetting, retires_at: date}),
    do: "Sunsets #{Date.to_iso8601(date)}. Keep a replacement enabled."

  def provider_lifecycle_note(%{lifecycle: :retired}),
    do: "Retained for compatibility only and excluded from new runs."

  def provider_lifecycle_note(%{lifecycle: :unofficial}),
    do: "Credential-free fallback with no official API contract."

  def provider_lifecycle_note(_descriptor), do: nil

  def filtered_descriptors(descriptors, filter) do
    filter = filter |> String.trim() |> String.downcase()

    if filter == "" do
      descriptors
    else
      Enum.filter(descriptors, fn descriptor ->
        haystack =
          [
            provider_name(descriptor),
            Atom.to_string(descriptor.lifecycle) | descriptor.capabilities
          ]
          |> Enum.map_join(" ", &to_string/1)
          |> String.downcase()

        String.contains?(haystack, filter)
      end)
    end
  end

  def provider_order(form, settings) do
    case Map.get(form_params(form), "search_provider_order") do
      order when is_list(order) and order != [] ->
        Enum.map(order, &to_string/1)

      order when is_binary(order) ->
        order
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> provider_order(settings)
          parsed -> parsed
        end

      _other ->
        provider_order(settings)
    end
  end

  def first_provider?(form, settings, provider),
    do: List.first(provider_order(form, settings)) == provider

  def last_provider?(form, settings, provider),
    do: List.last(provider_order(form, settings)) == provider

  def usage_value(row, key, default \\ nil), do: map_value(row, key, default)

  def usage_total_value(totals), do: max(map_value(totals, :tokens, 0), 0)

  def usage_cost_value(totals), do: max(map_value(totals, :cost_cents, 0), 0) / 100

  def format_usage_date(%DateTime{} = date), do: Calendar.strftime(date, "%b %d, %Y · %H:%M")
  def format_usage_date(%NaiveDateTime{} = date), do: Calendar.strftime(date, "%b %d, %Y · %H:%M")
  def format_usage_date(_date), do: "Unknown date"

  def research_effort_value(value) do
    case to_string(value || "medium") do
      "low" -> {"Low", "Fast evidence pass with conservative enforced ceilings."}
      "high" -> {"High", "Broad evidence gathering with verification and conflict review."}
      "ultra" -> {"Ultra", "Largest bounded investigation. Expect longer background execution."}
      _ -> {"Medium", "Balanced source coverage, verification, and runtime."}
    end
  end

  def optional_limit(value, _unit) when value in [nil, ""], do: "Preset ceiling"
  def optional_limit(value, unit), do: "#{value} #{unit}"

  def runtime_state_label(%{state: :idle}), do: "Idle"
  def runtime_state_label(%{state: :active}), do: "Active"
  def runtime_state_label(_runtime_status), do: "Unavailable"

  def runtime_state_tone(%{state: :idle}), do: "idle"
  def runtime_state_tone(%{state: :active}), do: "active"
  def runtime_state_tone(_runtime_status), do: "unavailable"

  def runtime_state_note(%{state: :idle}),
    do:
      "No queued or running agent work was detected. Dormant terminals are not counted as activity."

  def runtime_state_note(%{state: :active}),
    do: "One or more runs, agents, fleets, or research attempts are currently working."

  def runtime_state_note(_runtime_status),
    do: "Runtime activity could not be measured safely. The settings page remains available."

  def runtime_group(runtime_status, key) when is_map(runtime_status),
    do: map_value(runtime_status, key, %{})

  def runtime_group(_runtime_status, _key), do: %{}

  def runtime_count(group, key) do
    case map_value(group, key, nil) do
      value when is_integer(value) and value >= 0 -> Integer.to_string(value)
      _value -> "Unavailable"
    end
  end

  def runtime_dispatcher_value(dispatcher) do
    active = runtime_count(dispatcher, :active)
    queued = runtime_count(dispatcher, :queued)
    capacity = runtime_count(dispatcher, :capacity)

    if "Unavailable" in [active, queued, capacity] do
      "Unavailable"
    else
      "#{active} active · #{queued} queued · #{capacity} capacity"
    end
  end

  def runtime_memory_value(container) do
    current = format_runtime_bytes(map_value(container, :memory_current_bytes, nil))
    limit = format_runtime_limit(map_value(container, :memory_limit_bytes, nil))

    if current == "Unavailable" and limit == "Unavailable",
      do: "Unavailable",
      else: "#{current} / #{limit}"
  end

  def runtime_beam_memory_value(beam),
    do: format_runtime_bytes(map_value(beam, :memory_total_bytes, nil))

  def runtime_ports_value(beam) do
    count = runtime_count(beam, :port_count)
    limit = runtime_count(beam, :port_limit)

    if "Unavailable" in [count, limit], do: "Unavailable", else: "#{count} / #{limit}"
  end

  def form_error_count(form) do
    form.source
    |> case do
      %Changeset{} = changeset ->
        Changeset.traverse_errors(changeset, fn {_message, _opts} -> :error end)
        |> count_errors()

      _ ->
        0
    end
  end

  def status_title(:dirty), do: "Unsaved changes"
  def status_title(:saved), do: "Saved"
  def status_title(:error), do: "Needs attention"
  def status_title(:saving), do: "Saving"
  def status_title(_status), do: "Up to date"

  def status_text_class(:dirty), do: "text-amber-300"
  def status_text_class(:saved), do: "text-emerald-300"
  def status_text_class(:error), do: "text-rose-300"
  def status_text_class(_status), do: "text-gray-200"

  def usage_dom_id(row) do
    case usage_value(row, :id) do
      nil -> :erlang.phash2(row)
      id -> id
    end
  end

  defp count_errors(errors) when is_map(errors) do
    Enum.reduce(errors, 0, fn {_key, value}, count -> count + count_errors(value) end)
  end

  defp count_errors(errors) when is_list(errors), do: max(length(errors), 1)
  defp count_errors(_errors), do: 0

  defp load_context_session(nil), do: nil

  defp load_context_session(id) do
    Sessions.get_session(id)
  rescue
    _ -> nil
  end

  defp return_path(nil), do: ~p"/"
  defp return_path(session), do: ~p"/sessions/#{session.id}"

  defp settings_form(settings), do: Settings.change_settings(settings) |> to_form(as: :settings)

  defp draft_changeset(settings, params) do
    settings
    |> Settings.change_settings(normalize_form_params(params, settings))
    |> Map.put(:action, :validate)
  end

  defp normalize_form_params(params, settings) do
    if function_exported?(Settings, :normalize_form_params, 2) do
      apply(Settings, :normalize_form_params, [params, settings])
    else
      params
    end
  end

  defp update_from_form(settings, params) do
    if function_exported?(Settings, :update_settings_from_form, 2) do
      apply(Settings, :update_settings_from_form, [settings, params])
    else
      Settings.update_settings(normalize_form_params(params, settings))
    end
  end

  defp assign_saved(socket, updated, message) do
    socket
    |> assign(:settings, updated)
    |> assign(:settings_form, settings_form(updated))
    |> assign(:search_provider_descriptors, ordered_descriptors(updated))
    |> assign(:settings_status, :saved)
    |> assign(:settings_message, message)
    |> assign(:saved_at, DateTime.utc_now())
    |> assign(:external_update?, false)
    |> push_event("settings_clear_secrets", %{})
  end

  defp assign_save_error(socket, message, params) do
    socket
    |> assign(
      :settings_form,
      to_form(draft_changeset(socket.assigns.settings, params), as: :settings)
    )
    |> assign(:settings_status, :error)
    |> assign(:settings_message, message)
  end

  defp assign_cleared_credential(socket, updated, draft_params, credential_key) do
    draft_params = drop_cleared_credential(draft_params, credential_key)

    if socket.assigns.settings_status in [:dirty, :error] and map_size(draft_params) > 0 do
      changeset = draft_changeset(updated, draft_params)
      status = if changeset.valid?, do: :dirty, else: :error

      message =
        if changeset.valid?,
          do: "Credential removed. Your other edits remain unsaved.",
          else: "Credential removed. Your invalid draft is preserved for review."

      socket
      |> assign(:settings, updated)
      |> assign(:settings_form, to_form(changeset, as: :settings))
      |> assign(
        :search_provider_descriptors,
        ordered_descriptors(provider_order(to_form(changeset, as: :settings), updated))
      )
      |> assign(:settings_status, status)
      |> assign(:settings_message, message)
      |> assign(:saved_at, DateTime.utc_now())
      |> assign(:external_update?, false)
      |> push_event("settings_clear_secrets", %{})
    else
      assign_saved(socket, updated, "Credential removed")
    end
  end

  defp assign_reordered_draft(socket, draft_params, new_order) do
    changeset = draft_changeset(socket.assigns.settings, draft_params)
    status = if changeset.valid?, do: :dirty, else: :error

    message =
      if changeset.valid?,
        do: "Provider order changed. Save to apply it.",
        else: "Provider order changed in this draft. Review the highlighted fields before saving."

    socket
    |> assign(:settings_form, to_form(changeset, as: :settings))
    |> assign(:search_provider_descriptors, ordered_descriptors(new_order))
    |> assign(:settings_status, status)
    |> assign(:settings_message, message)
  end

  defp drop_cleared_credential(params, :openai), do: Map.delete(params, "openai_api_key")
  defp drop_cleared_credential(params, :anthropic), do: Map.delete(params, "anthropic_api_key")

  defp drop_cleared_credential(params, {:search, provider}) do
    case Map.get(params, "search_providers") do
      providers when is_map(providers) ->
        config = providers |> Map.get(provider, %{}) |> Map.delete("api_key")
        Map.put(params, "search_providers", Map.put(providers, provider, config))

      _providers ->
        params
    end
  end

  defp database_error(_reason),
    do: "The local settings database could not save this change. Try again."

  defp save_error({:db_error, reason}), do: database_error(reason)
  defp save_error(_reason), do: "Settings could not be saved. Your edits are still here."

  defp credential_key("openai"), do: {:ok, :openai}
  defp credential_key("anthropic"), do: {:ok, :anthropic}

  defp credential_key("provider:" <> provider) do
    if provider in Enum.map(SearchRegistry.names(), &Atom.to_string/1) do
      {:ok, {:search, provider}}
    else
      {:error, :unknown_credential}
    end
  end

  defp credential_key(_credential), do: {:error, :unknown_credential}

  defp ordered_descriptors(settings) when is_map(settings) do
    ordered_descriptors(provider_order(settings))
  end

  defp ordered_descriptors(order) when is_list(order) do
    by_id = Map.new(SearchRegistry.descriptors(), &{provider_id(&1), &1})

    order
    |> Enum.flat_map(fn id -> if descriptor = by_id[id], do: [descriptor], else: [] end)
  end

  defp provider_order(settings) do
    settings.search_provider_order || Enum.map(SearchRegistry.names(), &Atom.to_string/1)
  end

  defp move_in_order(order, provider, direction) do
    index = Enum.find_index(order, &(&1 == provider))
    destination = if direction == "up", do: index - 1, else: index + 1

    if destination in 0..(length(order) - 1) do
      other = Enum.at(order, destination)

      order
      |> List.replace_at(index, other)
      |> List.replace_at(destination, provider)
    else
      order
    end
  end

  defp toggle_set_member(set, value) do
    if MapSet.member?(set, value), do: MapSet.delete(set, value), else: MapSet.put(set, value)
  end

  defp form_params(%Phoenix.HTML.Form{params: params}) when is_map(params), do: params
  defp form_params(_form), do: %{}

  defp normalize_provider_config(config) do
    Map.new(config, fn {key, value} -> {to_string(key), value} end)
  end

  defp load_usage(session) do
    source = Application.get_env(:iex_code, :usage_reader, Sessions)
    opts = if session, do: [session_id: session.id], else: [scope: :global]

    empty_message =
      if session,
        do: "No provider-reported usage has been recorded for this session yet.",
        else: "No provider-reported usage has been recorded yet."

    with {:ok, rows} <- usage_history(source, opts),
         {:ok, totals} <- usage_totals(source, opts) do
      {status, rows, message} = normalize_usage_result(rows, empty_message)
      {status, rows, totals, message}
    else
      {:error, :session_scope_unavailable} ->
        {:unavailable, [], %{}, "Session-scoped usage is unavailable in this build."}

      {:error, _reason} ->
        {:error, [], %{}, "Usage telemetry is temporarily unavailable."}
    end
  rescue
    _ -> {:error, [], %{}, "Usage telemetry is temporarily unavailable."}
  end

  defp usage_history(source, opts) do
    _ = Code.ensure_loaded(source)

    cond do
      function_exported?(source, :fetch_usage_history, 2) ->
        apply(source, :fetch_usage_history, [100, opts])

      function_exported?(source, :list_usage_history, 2) ->
        {:ok, apply(source, :list_usage_history, [100, opts])}

      true ->
        {:error, :session_scope_unavailable}
    end
  end

  defp usage_totals(source, opts) do
    _ = Code.ensure_loaded(source)

    cond do
      function_exported?(source, :fetch_usage_totals, 1) ->
        apply(source, :fetch_usage_totals, [opts])

      function_exported?(source, :usage_totals, 1) ->
        {:ok, apply(source, :usage_totals, [opts])}

      true ->
        {:error, :usage_totals_unavailable}
    end
  end

  defp normalize_usage_result({:ok, rows}, empty_message) when is_list(rows),
    do: normalize_usage_result(rows, empty_message)

  defp normalize_usage_result({:error, :session_scope_unavailable}, _empty_message),
    do: {:unavailable, [], "Session-scoped usage is unavailable in this build."}

  defp normalize_usage_result({:error, _reason}, _empty_message),
    do: {:error, [], "Usage telemetry is temporarily unavailable."}

  defp normalize_usage_result(rows, empty_message) when is_list(rows) do
    rows = Enum.filter(rows, &(map_value(&1, :tokens, 0) > 0))
    if rows == [], do: {:empty, [], empty_message}, else: {:ready, rows, nil}
  end

  defp normalize_usage_result(_rows, _empty_message),
    do: {:error, [], "Usage telemetry is temporarily unavailable."}

  defp load_runtime_status do
    source = Application.get_env(:iex_code, :runtime_status_reader, RuntimeStatus)
    _ = Code.ensure_loaded(source)

    source
    |> apply(:snapshot, [])
    |> normalize_runtime_status()
  rescue
    _exception -> unavailable_runtime_status()
  catch
    _kind, _reason -> unavailable_runtime_status()
  end

  defp normalize_runtime_status(
         %{
           state: state,
           container: %{
             memory_current_bytes: container_memory,
             memory_limit_bytes: container_limit
           },
           beam: %{
             memory_total_bytes: beam_memory,
             port_count: port_count,
             port_limit: port_limit
           },
           dispatcher: %{active: active, queued: queued, capacity: capacity},
           activity: %{
             agents: agents,
             fleets: fleets,
             sessions: sessions,
             terminals: terminals,
             dag_attempts: dag_attempts
           }
         } = snapshot
       )
       when state in [:idle, :active, :unavailable] do
    counts = [
      container_memory,
      beam_memory,
      port_count,
      port_limit,
      active,
      queued,
      capacity,
      agents,
      fleets,
      sessions,
      terminals,
      dag_attempts
    ]

    valid_shape? =
      Enum.all?(counts, &optional_runtime_count?/1) and runtime_limit?(container_limit)

    valid_state? =
      case state do
        :idle ->
          Enum.all?([active, queued, agents, fleets, dag_attempts], &(&1 == 0))

        _active_or_unavailable ->
          true
      end

    if valid_shape? and valid_state?, do: snapshot, else: unavailable_runtime_status()
  end

  defp normalize_runtime_status(_snapshot), do: unavailable_runtime_status()

  defp unavailable_runtime_status, do: %{state: :unavailable}

  defp optional_runtime_count?(nil), do: true
  defp optional_runtime_count?(value), do: runtime_count?(value)

  defp runtime_count?(value), do: is_integer(value) and value >= 0

  defp runtime_limit?(:unlimited), do: true
  defp runtime_limit?(value), do: optional_runtime_count?(value)

  defp schedule_runtime_refresh do
    Process.send_after(self(), :refresh_runtime_status, @runtime_refresh_interval)
  end

  defp format_runtime_limit(:unlimited), do: "Unlimited"
  defp format_runtime_limit(value), do: format_runtime_bytes(value)

  defp format_runtime_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> format_runtime_unit(bytes / 1_073_741_824, "GiB")
      bytes >= 1_048_576 -> format_runtime_unit(bytes / 1_048_576, "MiB")
      bytes >= 1_024 -> format_runtime_unit(bytes / 1_024, "KiB")
      true -> "#{bytes} B"
    end
  end

  defp format_runtime_bytes(_bytes), do: "Unavailable"

  defp format_runtime_unit(value, unit) do
    precision = if value >= 10, do: 0, else: 1
    "#{:erlang.float_to_binary(value, decimals: precision)} #{unit}"
  end

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default)) || default
  end

  defp map_value(_map, _key, default), do: default

  defp same_settings_version?(left, right) do
    left == right
  end
end
