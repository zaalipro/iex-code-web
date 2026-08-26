defmodule IexCodeWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  with project-owned component styles. Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: IexCodeWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={
        [
          "fixed right-5 z-50 animate-in fade-in slide-in-from-bottom-3 duration-300 max-w-sm w-full cursor-pointer",
          # Stack info and error flashes instead of overlapping at the same spot
          @kind == :info && "bottom-5",
          @kind == :error && "bottom-24"
        ]
      }
      {@rest}
    >
      <div class="bg-[#11151c]/95 border border-[#21262d] rounded-2xl p-4 shadow-2xl backdrop-blur-xl relative group hover:border-[#38404a] transition-smooth">
        <!-- Top Header Row (Matching Reference Image) -->
        <div class="flex items-center gap-3 mb-2">
          <div class={[
            "w-8 h-8 rounded-xl flex items-center justify-center text-white shrink-0 shadow-md",
            @kind == :info && "bg-[#ff5e3a] shadow-orange-500/20",
            @kind == :error && "bg-rose-600 shadow-rose-500/20"
          ]}>
            <.icon
              :if={@kind == :info}
              name="hero-squares-2x2"
              class="w-4 h-4 text-white"
            />
            <.icon
              :if={@kind == :error}
              name="hero-shield-exclamation"
              class="w-4 h-4 text-white"
            />
          </div>

          <div class="flex-1 min-w-0">
            <h4 class="text-xs font-bold text-white tracking-tight truncate">
              {@title || if(@kind == :info, do: "System Notification", else: "Action Required")}
            </h4>
          </div>

          <button
            type="button"
            class="text-gray-500 hover:text-white p-1 rounded-lg transition-smooth"
            aria-label={gettext("close")}
          >
            <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
          </button>
        </div>

        <!-- Description Body -->
        <p class="text-xs text-gray-300 leading-relaxed font-sans mb-3">
          {msg}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Renders an important alert or status notification card matching the luxury dark aesthetic.
  """
  attr :title, :string, required: true
  attr :kind, :atom, default: :info, values: [:info, :warning, :error, :success]
  attr :source, :string, default: "EDR Agent (Swarm)"
  attr :hash, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def important_message(assigns) do
    ~H"""
    <div class={[
      "bg-[#11151c] border border-[#21262d] rounded-2xl p-4 shadow-xl font-sans text-xs transition-smooth",
      @class
    ]}>
      <!-- Top Header Row -->
      <div class="flex items-center gap-3 mb-2.5">
        <div class={[
          "w-8 h-8 rounded-xl flex items-center justify-center text-white shrink-0 shadow-md",
          @kind == :info && "bg-[#ff5e3a] shadow-orange-500/20",
          @kind == :warning && "bg-amber-500 shadow-amber-500/20",
          @kind == :error && "bg-rose-600 shadow-rose-500/20",
          @kind == :success && "bg-emerald-600 shadow-emerald-500/20"
        ]}>
          <.icon name="hero-squares-2x2" class="w-4 h-4 text-white" />
        </div>
        <h4 class="text-sm font-bold text-white tracking-tight">
          {@title}
        </h4>
      </div>

      <!-- Description Body -->
      <p class="text-xs text-gray-300 leading-relaxed mb-3">
        {render_slot(@inner_block)}
      </p>

      <!-- Metadata Key-Value Footer -->
      <div class="border-t border-dashed border-[#21262d] pt-2.5 space-y-1 font-mono text-[11px]">
        <div class="flex items-center justify-between text-gray-400">
          <span>Source</span>
          <span class="text-gray-200">{@source}</span>
        </div>
        <%= if @hash do %>
          <div class="flex items-center justify-between text-gray-400">
            <span>Hash</span>
            <span class="text-gray-300 truncate max-w-[200px]">{@hash}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" =>
        "inline-flex items-center justify-center rounded-xl bg-[#ff7e5f] px-4 py-2 text-sm font-semibold text-white transition-colors hover:bg-[#ff6b48] active:translate-y-px disabled:cursor-not-allowed disabled:opacity-50",
      nil =>
        "inline-flex items-center justify-center rounded-xl border border-[#30363d] bg-[#161b22] px-4 py-2 text-sm font-semibold text-gray-100 transition-colors hover:border-[#484f58] hover:bg-[#1c222b] active:translate-y-px disabled:cursor-not-allowed disabled:opacity-50"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        Map.fetch!(variants, assigns[:variant])
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="flex items-center gap-2 text-sm text-gray-300">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={describe_errors(@errors, @id)}
            class={
              @class ||
                "h-4 w-4 rounded border-[#484f58] bg-[#0d1117] text-[#ff7e5f] accent-[#ff7e5f] focus:ring-2 focus:ring-[#79c0ff]"
            }
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={{msg, idx} <- Enum.with_index(@errors)} id={"#{@id}-error-#{idx}"}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-xs font-medium text-gray-300">{@label}</span>
        <select
          id={@id}
          name={@name}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={describe_errors(@errors, @id)}
          class={[
            @class ||
              "w-full bg-[#0d1117] border border-[#30363d] focus:border-[#ff5e3a] text-white rounded-xl px-3 py-2 text-xs font-sans focus:outline-hidden",
            @errors != [] && (@error_class || "border-red-500 text-red-300")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={{msg, idx} <- Enum.with_index(@errors)} id={"#{@id}-error-#{idx}"}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-xs font-medium text-gray-300">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={describe_errors(@errors, @id)}
          class={[
            @class ||
              "w-full rounded-xl border border-[#30363d] bg-[#0d1117] px-3 py-2 text-sm text-white placeholder-gray-600 outline-none transition-colors focus:border-[#79c0ff]",
            @errors != [] && (@error_class || "border-rose-500 text-rose-200")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={{msg, idx} <- Enum.with_index(@errors)} id={"#{@id}-error-#{idx}"}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-2">
      <label for={@id}>
        <span :if={@label} class="mb-1 block text-xs font-medium text-gray-300">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={describe_errors(@errors, @id)}
          class={[
            @class ||
              "w-full rounded-xl border border-[#30363d] bg-[#0d1117] px-3 py-2 text-sm text-white placeholder-gray-600 outline-none transition-colors focus:border-[#79c0ff]",
            @errors != [] && (@error_class || "border-rose-500 text-rose-200")
          ]}
          {@rest}
        />
      </label>
      <.error :for={{msg, idx} <- Enum.with_index(@errors)} id={"#{@id}-error-#{idx}"}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp error(assigns) do
    ~H"""
    <p id={@id} class="mt-1.5 flex items-center gap-2 text-sm text-rose-400">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  defp describe_errors([], _id), do: nil

  defp describe_errors(errors, id) when is_binary(id) do
    Enum.map_join(0..(length(errors) - 1), " ", &"#{id}-error-#{&1}")
  end

  defp describe_errors(_errors, _id), do: nil

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(IexCodeWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(IexCodeWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
