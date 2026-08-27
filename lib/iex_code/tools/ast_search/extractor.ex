defmodule IexCode.Tools.ASTSearch.Extractor do
  @moduledoc """
  AST traversal and symbol extractor for Elixir source code.
  Extracts modules, functions, macros, @spec, @doc/@moduledoc, @type, @callback,
  and module attributes with precise metadata (file, line, column, arity, visibility).
  """

  @type symbol_type ::
          :module
          | :function
          | :macro
          | :spec
          | :doc
          | :moduledoc
          | :attribute
          | :type
          | :callback
          | :defguard
          | :defdelegate

  @type visibility :: :public | :private

  @type symbol_entry :: %{
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          end_line: pos_integer() | nil,
          type: symbol_type(),
          name: String.t(),
          arity: non_neg_integer() | nil,
          visibility: visibility(),
          module: String.t() | nil,
          code: String.t(),
          metadata: map()
        }

  @doc """
  Extracts all AST symbols from Elixir source code.
  """
  @spec extract(String.t(), String.t()) :: {:ok, [symbol_entry()]} | {:error, term()}
  def extract(source_code, file_path \\ "") when is_binary(source_code) do
    case extract_matching(source_code, file_path, fn _entry -> true end, limit: :infinity) do
      {:ok, %{symbols: symbols}} -> {:ok, symbols}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec extract_matching(String.t(), String.t(), (symbol_entry() -> boolean()), keyword()) ::
          {:ok, %{symbols: [symbol_entry()], truncated?: boolean()}} | {:error, term()}
  def extract_matching(source_code, file_path, accept?, opts \\ [])
      when is_binary(source_code) and is_function(accept?, 1) and is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, :infinity))
    entry_transform = Keyword.get(opts, :entry_transform, fn entry -> entry end)

    case Code.string_to_quoted(source_code, columns: true, token_metadata: true) do
      {:ok, ast} ->
        lines = String.split(source_code, ~r/\r?\n/)

        {symbols, truncated?} =
          traverse_ast(ast, file_path, lines, accept?, entry_transform, limit)

        {:ok, %{symbols: Enum.reverse(symbols), truncated?: truncated?}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Traverses AST maintaining module context stack
  defp traverse_ast(ast, file_path, lines, accept?, entry_transform, limit) do
    {_ast, {symbols, _mod_stack, _count, truncated?}} =
      Macro.traverse(
        ast,
        {[], [], 0, false},
        fn node, {acc, mod_stack, count, truncated?} ->
          case parse_node_pre(node, file_path, mod_stack, lines) do
            {:module, entry, new_mod_name} ->
              {acc, count, truncated?} =
                retain_entry(
                  entry,
                  acc,
                  count,
                  truncated?,
                  accept?,
                  entry_transform,
                  limit
                )

              {node, {acc, [new_mod_name | mod_stack], count, truncated?}}

            {:symbol, entry} ->
              {acc, count, truncated?} =
                retain_entry(
                  entry,
                  acc,
                  count,
                  truncated?,
                  accept?,
                  entry_transform,
                  limit
                )

              {node, {acc, mod_stack, count, truncated?}}

            :skip ->
              {node, {acc, mod_stack, count, truncated?}}
          end
        end,
        fn node, {acc, mod_stack, count, truncated?} ->
          # On post-walk of module-like definitions, pop module stack
          case node do
            {def_kind, _, _} when def_kind in [:defmodule, :defprotocol, :defimpl] ->
              new_mod_stack = if mod_stack == [], do: [], else: tl(mod_stack)
              {node, {acc, new_mod_stack, count, truncated?}}

            _ ->
              {node, {acc, mod_stack, count, truncated?}}
          end
        end
      )

    {symbols, truncated?}
  end

  defp retain_entry(entry, acc, count, truncated?, accept?, entry_transform, limit) do
    if accept?.(entry) do
      if limit == :infinity or count < limit do
        {[entry_transform.(entry) | acc], count + 1, truncated?}
      else
        {acc, count, true}
      end
    else
      {acc, count, truncated?}
    end
  end

  defp normalize_limit(:infinity), do: :infinity
  defp normalize_limit(limit) when is_integer(limit) and limit >= 0, do: limit
  defp normalize_limit(_invalid), do: 0

  defp current_module_name([]), do: nil
  defp current_module_name([mod | _]), do: mod

  # defmodule / defprotocol / defimpl — module-like entries
  defp parse_node_pre({def_kind, meta, [mod_ast | _]}, file_path, mod_stack, lines)
       when def_kind in [:defmodule, :defprotocol, :defimpl] do
    mod_name = extract_module_name(mod_ast)

    full_mod_name =
      case mod_stack do
        [] -> mod_name
        [parent | _] -> "#{parent}.#{mod_name}"
      end

    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    code_snippet = extract_snippet(lines, line, end_line)

    # Unquote fragments cannot be resolved statically — flag them instead of
    # presenting the raw fragment as a real module name.
    metadata = module_metadata(def_kind, mod_ast, full_mod_name)

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: :defmodule,
      name: full_mod_name,
      arity: nil,
      visibility: :public,
      module: current_module_name(mod_stack),
      code: code_snippet || "#{def_kind} #{full_mod_name}",
      metadata: metadata
    }

    {:module, entry, full_mod_name}
  end

  # def / defp
  defp parse_node_pre({def_type, meta, [head | _]}, file_path, mod_stack, lines)
       when def_type in [:def, :defp] do
    {name, arity} = extract_fn_name_arity(head)
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    code_snippet = extract_snippet(lines, line, end_line)
    visibility = if def_type == :def, do: :public, else: :private

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: def_type,
      name: to_string(name),
      arity: arity,
      visibility: visibility,
      module: current_module_name(mod_stack),
      code: code_snippet || "#{def_type} #{name}",
      metadata: %{head: Macro.to_string(head)}
    }

    {:symbol, entry}
  end

  # defmacro / defmacrop
  defp parse_node_pre({macro_type, meta, [head | _]}, file_path, mod_stack, lines)
       when macro_type in [:defmacro, :defmacrop] do
    {name, arity} = extract_fn_name_arity(head)
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    code_snippet = extract_snippet(lines, line, end_line)
    visibility = if macro_type == :defmacro, do: :public, else: :private

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: macro_type,
      name: to_string(name),
      arity: arity,
      visibility: visibility,
      module: current_module_name(mod_stack),
      code: code_snippet || "#{macro_type} #{name}",
      metadata: %{head: Macro.to_string(head)}
    }

    {:symbol, entry}
  end

  # defguard / defguardp
  defp parse_node_pre({guard_kind, meta, [head | _]}, file_path, mod_stack, lines)
       when guard_kind in [:defguard, :defguardp] do
    {name, arity} = extract_fn_name_arity(head)
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    code_snippet = extract_snippet(lines, line, end_line)
    visibility = if guard_kind == :defguard, do: :public, else: :private

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: :defguard,
      name: to_string(name),
      arity: arity,
      visibility: visibility,
      module: current_module_name(mod_stack),
      code: code_snippet || "#{guard_kind} #{name}",
      metadata: %{head: Macro.to_string(head)}
    }

    {:symbol, entry}
  end

  # defdelegate
  defp parse_node_pre({:defdelegate, meta, [head | _]}, file_path, mod_stack, lines) do
    {name, arity} = extract_fn_name_arity(head)
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    code_snippet = extract_snippet(lines, line, end_line)

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: :defdelegate,
      name: to_string(name),
      arity: arity,
      visibility: :public,
      module: current_module_name(mod_stack),
      code: code_snippet || "defdelegate #{name}",
      metadata: %{head: Macro.to_string(head)}
    }

    {:symbol, entry}
  end

  # @spec
  defp parse_node_pre({:@, meta, [{:spec, _, [spec_ast]}]}, file_path, mod_stack, lines) do
    {name, arity} = extract_spec_target(spec_ast)
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    spec_str = Macro.to_string(spec_ast)
    code_snippet = extract_snippet(lines, line, end_line)

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: :spec,
      name: to_string(name || "spec"),
      arity: arity,
      visibility: :public,
      module: current_module_name(mod_stack),
      code: code_snippet || "@spec #{spec_str}",
      metadata: %{spec: spec_str}
    }

    {:symbol, entry}
  end

  # @doc / @moduledoc
  defp parse_node_pre({:@, meta, [{doc_type, _, [doc_val]}]}, file_path, mod_stack, lines)
       when doc_type in [:doc, :moduledoc] do
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    doc_str = extract_doc_string(doc_val)
    code_snippet = extract_snippet(lines, line, end_line)

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: if(doc_type == :doc, do: :doc, else: :moduledoc),
      name: "@#{doc_type}",
      arity: nil,
      visibility: :public,
      module: current_module_name(mod_stack),
      code: code_snippet || "@#{doc_type} #{inspect(doc_str)}",
      metadata: %{doc: doc_str}
    }

    {:symbol, entry}
  end

  # @type / @typep / @opaque
  defp parse_node_pre({:@, meta, [{type_kind, _, [type_ast]}]}, file_path, mod_stack, lines)
       when type_kind in [:type, :typep, :opaque] do
    {name, arity} = extract_spec_target(type_ast)
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    code_snippet = extract_snippet(lines, line, end_line)
    visibility = if type_kind == :typep, do: :private, else: :public

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: :type,
      name: to_string(name || "type"),
      arity: arity,
      visibility: visibility,
      module: current_module_name(mod_stack),
      code: code_snippet || "@#{type_kind} #{Macro.to_string(type_ast)}",
      metadata: %{kind: type_kind, definition: Macro.to_string(type_ast)}
    }

    {:symbol, entry}
  end

  # @callback / @macrocallback
  defp parse_node_pre({:@, meta, [{cb_kind, _, [cb_ast]}]}, file_path, mod_stack, lines)
       when cb_kind in [:callback, :macrocallback] do
    {name, arity} = extract_spec_target(cb_ast)
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    code_snippet = extract_snippet(lines, line, end_line)

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: :callback,
      name: to_string(name || "callback"),
      arity: arity,
      visibility: :public,
      module: current_module_name(mod_stack),
      code: code_snippet || "@#{cb_kind} #{Macro.to_string(cb_ast)}",
      metadata: %{kind: cb_kind, definition: Macro.to_string(cb_ast)}
    }

    {:symbol, entry}
  end

  # Module attributes: @name value
  defp parse_node_pre({:@, meta, [{attr_name, _, args}]}, file_path, mod_stack, lines)
       when is_atom(attr_name) and
              attr_name not in [
                :spec,
                :doc,
                :moduledoc,
                :type,
                :typep,
                :opaque,
                :callback,
                :macrocallback
              ] do
    line = meta[:line] || 1
    col = meta[:column] || 1
    end_line = meta[:end_of_expression][:line] || line
    code_snippet = extract_snippet(lines, line, end_line)
    val_str = if is_list(args), do: Enum.map_join(args, ", ", &Macro.to_string/1), else: ""

    entry = %{
      file: file_path,
      line: line,
      column: col,
      end_line: end_line,
      type: :attribute,
      name: "@#{attr_name}",
      arity: nil,
      visibility: :public,
      module: current_module_name(mod_stack),
      code: code_snippet || "@#{attr_name} #{val_str}",
      metadata: %{attribute: attr_name, value: val_str}
    }

    {:symbol, entry}
  end

  defp parse_node_pre(_node, _file_path, _mod_stack, _lines), do: :skip

  # --- Helpers ---

  defp extract_module_name({:__aliases__, _, aliases}) do
    Enum.map_join(aliases, ".", &to_string/1)
  end

  defp extract_module_name(atom) when is_atom(atom) do
    atom |> to_string() |> String.trim_leading("Elixir.")
  end

  defp extract_module_name(other), do: Macro.to_string(other)

  defp module_metadata(def_kind, mod_ast, full_mod_name) do
    metadata = %{kind: def_kind, raw: Macro.to_string(mod_ast)}

    if String.contains?(full_mod_name, "unquote") do
      Map.put(metadata, :name_unresolved, true)
    else
      metadata
    end
  end

  defp extract_fn_name_arity({:when, _, [head | _]}), do: extract_fn_name_arity(head)

  defp extract_fn_name_arity({name, _, args}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {name, arity}
  end

  defp extract_fn_name_arity(_), do: {"unknown", 0}

  defp extract_spec_target({:when, _, [head | _]}), do: extract_spec_target(head)

  defp extract_spec_target({:"::", _, [{name, _, args} | _]}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {name, arity}
  end

  defp extract_spec_target({name, _, args}) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {name, arity}
  end

  defp extract_spec_target(_), do: {nil, nil}

  defp extract_doc_string(doc_val) when is_binary(doc_val), do: doc_val
  defp extract_doc_string(false), do: "false"
  defp extract_doc_string(other), do: Macro.to_string(other)

  @snippet_max_lines 10

  defp extract_snippet(lines, start_l, end_l) do
    if is_list(lines) and lines != [] and is_integer(start_l) and start_l > 0 do
      max_end =
        if is_integer(end_l) and end_l >= start_l,
          do: min(end_l, start_l + @snippet_max_lines),
          else: start_l

      slice = Enum.slice(lines, (start_l - 1)..(max_end - 1))
      snippet = Enum.join(slice, "\n")

      if is_integer(end_l) and end_l > max_end do
        snippet <> "\n# ... (truncated)"
      else
        snippet
      end
    else
      nil
    end
  end
end
