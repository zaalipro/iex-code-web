defmodule IexCode.Tools.ASTSearch.Query do
  @moduledoc """
  Query parser and filtering engine for ASTSearch symbols.
  Supports keyword strings, exact atom/string filters, arity, line ranges,
  regex patterns, and symbol type constraints.
  """

  alias IexCode.Tools.ASTSearch.Extractor

  @doc """
  Filters a list of symbol entries based on the given query.
  Query can be a binary string, a map, or a keyword list.

  Returns the filtered list for valid queries, or `{:error, reason}` for
  malformed queries (unknown query shape, or a field value of the wrong type
  such as a non-numeric `:arity`). A malformed query never degrades to
  matching everything.
  """
  @spec filter([Extractor.symbol_entry()], String.t() | map() | keyword()) ::
          [Extractor.symbol_entry()] | {:error, term()}
  def filter(symbols, query) do
    case compile(query) do
      {:ok, matcher} -> Enum.filter(symbols, matcher)
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec compile(String.t() | map() | keyword()) ::
          {:ok, (Extractor.symbol_entry() -> boolean())} | {:error, term()}
  def compile(query) when is_binary(query) do
    q = String.trim(query)

    if q == "" do
      {:ok, fn _symbol -> true end}
    else
      q_down = String.downcase(q)

      {:ok,
       fn s ->
         name_match = is_binary(s.name) and String.contains?(String.downcase(s.name), q_down)
         mod_match = is_binary(s.module) and String.contains?(String.downcase(s.module), q_down)
         code_match = is_binary(s.code) and String.contains?(String.downcase(s.code), q_down)
         doc_match = match_doc_text(s.metadata, q_down)

         name_match or mod_match or code_match or doc_match
       end}
    end
  end

  def compile(query) when is_list(query) do
    if Keyword.keyword?(query) do
      compile(Map.new(query))
    else
      {:error, :invalid_query}
    end
  end

  def compile(query) when is_map(query) do
    case validate_query(query) do
      :ok ->
        {:ok,
         fn s ->
           matches_type?(s, query_get(query, [:type])) and
             matches_name?(s, query_get(query, [:function, :name])) and
             matches_module?(s, query_get(query, [:module])) and
             matches_arity?(s, query_get(query, [:arity])) and
             matches_visibility?(s, query_get(query, [:visibility])) and
             matches_line?(s, query_get(query, [:line])) and
             matches_path?(s, query_get(query, [:path, :file])) and
             matches_text?(s, query_get(query, [:text, :query]))
         end}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def compile(_query), do: {:error, :invalid_query}

  # --- Query Validation ---

  # Validates field value types up-front so malformed queries fail with an
  # error instead of silently matching everything (or crashing).
  defp validate_query(query) do
    validators = [
      {:type, [:type], &valid_type_value?/1},
      {:name, [:function, :name], &valid_name_value?/1},
      {:module, [:module], &valid_name_value?/1},
      {:arity, [:arity], &valid_arity_value?/1},
      {:visibility, [:visibility], &valid_visibility_value?/1},
      {:line, [:line], &valid_line_value?/1},
      {:path, [:path, :file], &is_binary/1},
      {:text, [:text, :query], &is_binary/1}
    ]

    Enum.find_value(validators, :ok, fn {key, query_keys, valid?} ->
      value = query_get(query, query_keys)

      if value != nil and not valid?.(value) do
        {:error, {:invalid_query, {key, value}}}
      end
    end)
  end

  defp valid_type_value?(v), do: is_atom(v) or is_binary(v)
  defp valid_name_value?(v), do: is_binary(v) or is_atom(v) or is_struct(v, Regex)

  defp valid_arity_value?(v), do: is_integer(v) or (is_binary(v) and strict_integer?(v))

  defp valid_visibility_value?(v),
    do: v in [:public, :private, :all] or v in ["public", "private", "all"]

  defp valid_line_value?(v), do: is_integer(v) or (is_binary(v) and strict_integer?(v))

  defp strict_integer?(v) do
    case Integer.parse(v) do
      {_, ""} -> true
      _ -> false
    end
  end

  # --- Internal Matchers ---

  defp query_get(map, keys) do
    Enum.find_value(keys, fn k ->
      Map.get(map, k) || Map.get(map, to_string(k))
    end)
  end

  defp matches_type?(_s, nil), do: true
  defp matches_type?(_s, :all), do: true
  defp matches_type?(_s, "all"), do: true
  defp matches_type?(s, :module), do: s.type in [:module, :defmodule]
  defp matches_type?(s, :defmodule), do: s.type in [:module, :defmodule]
  defp matches_type?(s, :function), do: s.type in [:function, :def, :defp]
  defp matches_type?(s, :def), do: s.type in [:def, :function]
  defp matches_type?(s, :defp), do: s.type == :defp
  defp matches_type?(s, :macro), do: s.type in [:macro, :defmacro, :defmacrop]
  defp matches_type?(s, :defmacro), do: s.type in [:defmacro, :macro]
  defp matches_type?(s, :defmacrop), do: s.type == :defmacrop
  defp matches_type?(s, :spec), do: s.type == :spec
  defp matches_type?(s, :doc), do: s.type in [:doc, :moduledoc]
  defp matches_type?(s, :moduledoc), do: s.type == :moduledoc
  defp matches_type?(s, :attribute), do: s.type == :attribute
  defp matches_type?(s, :type), do: s.type == :type
  defp matches_type?(s, :callback), do: s.type == :callback
  defp matches_type?(s, type) when is_atom(type), do: s.type == type

  defp matches_type?(s, type) when is_binary(type) do
    case String.downcase(String.trim(type)) do
      "all" -> true
      "module" -> s.type in [:module, :defmodule]
      "defmodule" -> s.type in [:module, :defmodule]
      "function" -> s.type in [:function, :def, :defp]
      "def" -> s.type in [:def, :function]
      "defp" -> s.type == :defp
      "macro" -> s.type in [:macro, :defmacro, :defmacrop]
      "defmacro" -> s.type in [:defmacro, :macro]
      "defmacrop" -> s.type == :defmacrop
      "spec" -> s.type == :spec
      "doc" -> s.type in [:doc, :moduledoc]
      "moduledoc" -> s.type == :moduledoc
      "attribute" -> s.type == :attribute
      "type" -> s.type == :type
      "callback" -> s.type == :callback
      other -> to_string(s.type) == other
    end
  end

  defp matches_name?(_s, nil), do: true

  defp matches_name?(s, name) when is_binary(name) and is_binary(s.name) do
    String.downcase(s.name) == String.downcase(name) or
      String.contains?(String.downcase(s.name), String.downcase(name))
  end

  defp matches_name?(s, name) when is_atom(name) and is_binary(s.name),
    do: matches_name?(s, to_string(name))

  defp matches_name?(s, %Regex{} = regex) when is_binary(s.name), do: Regex.match?(regex, s.name)

  # Non-binary symbol names (e.g. from unquote fragments) never match.
  defp matches_name?(_s, _name), do: false

  defp matches_module?(_s, nil), do: true

  defp matches_module?(s, mod) when is_binary(mod) do
    mod_str = String.downcase(mod)
    target_mod = String.downcase(module_target(s))
    target_mod == mod_str or String.contains?(target_mod, mod_str)
  end

  defp matches_module?(s, mod) when is_atom(mod), do: matches_module?(s, to_string(mod))

  defp matches_module?(s, %Regex{} = regex), do: Regex.match?(regex, module_target(s))

  # Module entries (:defmodule/:module) are matched against their own
  # fully-qualified name, not the parent module stored in `:module`
  # (which is what nested defmodule entries carry in that field).
  defp module_target(%{type: type, name: name})
       when type in [:module, :defmodule] and is_binary(name),
       do: name

  defp module_target(%{module: module}) when is_binary(module), do: module
  defp module_target(_), do: ""

  defp matches_arity?(_s, nil), do: true
  defp matches_arity?(s, arity) when is_integer(arity), do: s.arity == arity

  defp matches_arity?(s, arity_str) when is_binary(arity_str) do
    case Integer.parse(arity_str) do
      {a, ""} -> s.arity == a
      _ -> false
    end
  end

  defp matches_visibility?(_s, nil), do: true
  defp matches_visibility?(_s, :all), do: true
  defp matches_visibility?(_s, "all"), do: true
  defp matches_visibility?(s, :public), do: s.visibility == :public
  defp matches_visibility?(s, :private), do: s.visibility == :private
  defp matches_visibility?(s, "public"), do: s.visibility == :public
  defp matches_visibility?(s, "private"), do: s.visibility == :private
  defp matches_visibility?(_s, _), do: false

  defp matches_line?(_s, nil), do: true

  defp matches_line?(s, line) when is_integer(line) do
    start_l = s.line
    end_l = s.end_line || s.line
    line >= start_l and line <= end_l
  end

  defp matches_line?(s, line_str) when is_binary(line_str) do
    case Integer.parse(line_str) do
      {l, ""} -> matches_line?(s, l)
      _ -> false
    end
  end

  defp matches_path?(_s, nil), do: true

  defp matches_path?(s, path) when is_binary(path) and is_binary(s.file) do
    String.contains?(s.file, path)
  end

  defp matches_path?(_s, _path), do: false

  defp matches_text?(_s, nil), do: true

  defp matches_text?(s, text) when is_binary(text) do
    t_down = String.downcase(text)
    code_match = is_binary(s.code) and String.contains?(String.downcase(s.code), t_down)
    name_match = is_binary(s.name) and String.contains?(String.downcase(s.name), t_down)

    code_match or name_match
  end

  defp match_doc_text(%{doc: doc}, q_down) when is_binary(doc) do
    String.contains?(String.downcase(doc), q_down)
  end

  defp match_doc_text(_, _), do: false
end
