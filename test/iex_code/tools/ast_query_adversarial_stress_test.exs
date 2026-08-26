defmodule IexCode.Tools.ASTQueryAdversarialStressTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.ASTSearch
  alias IexCode.Tools.ASTSearch.Query

  @complex_elixir_code """
  defmodule Complex.ParentModule do
    @moduledoc \"\"\"
    Parent module documentation with markdown and multiple lines.
    \"\"\"
    @behaviour GenServer
    @derive [Inspect]

    @app_version "2.4.0"
    @timeout_ms 5_000

    @type result_t :: {:ok, term()} | {:error, atom()}
    @typep internal_state :: %{count: non_neg_integer(), flag: boolean()}
    @opaque secret_token :: binary()
    @callback handle_action(term(), internal_state()) :: result_t()
    @macrocallback define_hook(atom()) :: Macro.t()

    @doc "Calculates total with default args and guards"
    @spec calculate(integer(), integer(), keyword()) :: {:ok, integer()} | {:error, String.t()}
    def calculate(a, b \\\\ 10, opts \\\\[])
        when is_integer(a) and is_integer(b) and is_list(opts) do
      factor = Keyword.get(opts, :factor, 1)
      {:ok, (a + b) * factor}
    end

    @doc false
    defp private_helper(arg) when not is_nil(arg) do
      {arg, @app_version}
    end

    defmacro custom_builder(name, do: block) do
      quote do
        def unquote(name)(), do: unquote(block)
      end
    end

    defmacrop private_macro_calc(expr) do
      quote do: unquote(expr) * 2
    end

    defmodule NestedChild do
      @moduledoc "Child module inside parent"
      @spec child_action() :: :ok
      def child_action, do: :ok

      defp child_private(x), do: x + 1
    end
  end
  """

  describe "Adversarial AST Symbol Extraction" do
    test "extracts full matrix of definitions, specs, docs, attributes, types, callbacks, and nested modules" do
      {:ok, symbols} = ASTSearch.extract_symbols(@complex_elixir_code, "lib/complex.ex")

      # 1. Module definitions
      modules = Enum.filter(symbols, &(&1.type in [:module, :defmodule]))
      assert length(modules) == 2
      mod_names = Enum.map(modules, & &1.name)
      assert "Complex.ParentModule" in mod_names
      assert "Complex.ParentModule.NestedChild" in mod_names or "NestedChild" in mod_names

      # 2. Public functions with multiline guards & default args
      pub_func = Enum.find(symbols, &(&1.name == "calculate" and &1.type in [:def, :function]))
      assert pub_func != nil
      assert pub_func.arity == 3
      assert pub_func.visibility == :public
      assert pub_func.module =~ "Complex.ParentModule"
      assert is_integer(pub_func.line)
      assert is_integer(pub_func.end_line)
      assert pub_func.end_line >= pub_func.line

      # 3. Private functions
      priv_func = Enum.find(symbols, &(&1.name == "private_helper"))
      assert priv_func != nil
      assert priv_func.arity == 1
      assert priv_func.visibility == :private

      # 4. Public and private macros
      pub_macro = Enum.find(symbols, &(&1.name == "custom_builder"))
      assert pub_macro != nil
      assert pub_macro.type in [:macro, :defmacro]
      assert pub_macro.visibility == :public

      priv_macro = Enum.find(symbols, &(&1.name == "private_macro_calc"))
      assert priv_macro != nil
      assert priv_macro.type in [:macro, :defmacrop]
      assert priv_macro.visibility == :private

      # 5. Types & callbacks
      type_names = Enum.filter(symbols, &(&1.type == :type)) |> Enum.map(& &1.name)
      assert "result_t" in type_names
      assert "internal_state" in type_names
      assert "secret_token" in type_names

      callback_names = Enum.filter(symbols, &(&1.type == :callback)) |> Enum.map(& &1.name)
      assert "handle_action" in callback_names
      assert "define_hook" in callback_names

      # 6. Specs & docs
      specs = Enum.filter(symbols, &(&1.type == :spec))
      assert Enum.any?(specs, &(&1.name == "calculate" and &1.arity == 3))

      docs = Enum.filter(symbols, &(&1.type in [:doc, :moduledoc]))
      assert Enum.any?(docs, &(&1.type == :moduledoc))
      assert Enum.any?(docs, &(&1.type == :doc))
    end
  end

  describe "Adversarial Query Filtering" do
    setup do
      {:ok, symbols} = ASTSearch.extract_symbols(@complex_elixir_code, "lib/complex.ex")
      {:ok, %{symbols: symbols}}
    end

    test "handles empty strings, whitespace, and empty maps by returning all symbols", %{
      symbols: symbols
    } do
      assert Query.filter(symbols, "") == symbols
      assert Query.filter(symbols, "   ") == symbols
      assert Query.filter(symbols, %{}) == symbols
      assert Query.filter(symbols, %{type: "all", visibility: "all"}) == symbols
      assert Query.filter(symbols, %{type: :all, visibility: :all}) == symbols
    end

    test "filters across type constraints accurately", %{symbols: symbols} do
      # Functions (both def and defp)
      funcs = Query.filter(symbols, %{type: "function"})
      assert length(funcs) >= 4
      assert Enum.all?(funcs, &(&1.type in [:def, :defp, :function]))

      # Public functions only
      pub_funcs = Query.filter(symbols, %{type: "def", visibility: "public"})
      assert Enum.all?(pub_funcs, &(&1.visibility == :public and &1.type in [:def, :function]))
      assert Enum.any?(pub_funcs, &(&1.name == "calculate"))
      refute Enum.any?(pub_funcs, &(&1.name == "private_helper"))

      # Private functions only
      priv_funcs = Query.filter(symbols, %{type: "defp", visibility: "private"})
      assert Enum.all?(priv_funcs, &(&1.visibility == :private and &1.type in [:defp, :function]))
      assert Enum.any?(priv_funcs, &(&1.name == "private_helper"))
      refute Enum.any?(priv_funcs, &(&1.name == "calculate"))

      # Macros
      macros = Query.filter(symbols, %{type: "macro"})
      assert length(macros) >= 2
      assert Enum.any?(macros, &(&1.name == "custom_builder"))
      assert Enum.any?(macros, &(&1.name == "private_macro_calc"))

      # Specs
      specs = Query.filter(symbols, %{type: "spec"})
      assert length(specs) >= 2
      assert Enum.all?(specs, &(&1.type == :spec))

      # Types
      types = Query.filter(symbols, %{type: "type"})
      assert length(types) >= 3
      assert Enum.all?(types, &(&1.type == :type))

      # Callbacks
      callbacks = Query.filter(symbols, %{type: "callback"})
      assert length(callbacks) >= 2
      assert Enum.all?(callbacks, &(&1.type == :callback))

      # Modules
      mods = Query.filter(symbols, %{type: "module"})
      assert length(mods) >= 2
      assert Enum.all?(mods, &(&1.type in [:module, :defmodule]))
    end

    test "filters by regex name and module pattern", %{symbols: symbols} do
      # Regex matching function names ending with '_helper' or '_action'
      res = Query.filter(symbols, %{name: ~r/_(helper|action)$/})
      matched_names = Enum.map(res, & &1.name)
      assert "private_helper" in matched_names
      assert "child_action" in matched_names

      # Regex matching module
      child_res = Query.filter(symbols, %{module: ~r/NestedChild/})
      assert length(child_res) >= 2
    end

    test "handles malformed queries safely with structured error", %{symbols: symbols} do
      # Invalid arity type (should return {:error, ...} instead of crashing)
      assert {:error, {:invalid_query, {:arity, "not_an_int"}}} =
               Query.filter(symbols, %{arity: "not_an_int"})

      # Invalid visibility value
      assert {:error, {:invalid_query, {:visibility, :super_private}}} =
               Query.filter(symbols, %{visibility: :super_private})

      # Invalid query shape
      assert {:error, :invalid_query} = Query.filter(symbols, [:not_a_keyword_tuple])
      assert {:error, :invalid_query} = Query.filter(symbols, 12345)
    end
  end

  describe "Filesystem Search & Syntax Error Resiliency" do
    @tag :tmp_dir
    test "scans multiple files, ignores excluded paths, and skips broken syntax gracefully", %{
      tmp_dir: tmp_dir
    } do
      # Good file
      File.write!(Path.join(tmp_dir, "valid.ex"), """
      defmodule Adversarial.Valid do
        def ping, do: :pong
      end
      """)

      # Broken syntax file
      File.write!(Path.join(tmp_dir, "syntax_error.ex"), """
      defmodule Adversarial.Broken do
        def unclosed(a, do: 123
      """)

      # Binary / Non-utf8 file with .ex extension
      File.write!(Path.join(tmp_dir, "corrupt.ex"), <<0, 255, 128, 64, 32, 16>>)

      # Empty file
      File.write!(Path.join(tmp_dir, "empty.ex"), "")

      # Subdirectory in excluded path (_build, deps, .git)
      deps_dir = Path.join(tmp_dir, "deps/some_pkg")
      File.mkdir_p!(deps_dir)
      File.write!(Path.join(deps_dir, "dep.ex"), "defmodule Dep, do: def foo, do: 1\n")

      # Execute search
      assert {:ok, results} = ASTSearch.search(tmp_dir, %{type: "def"})

      names = Enum.map(results, & &1.name)
      assert "ping" in names
      # Excluded deps directory must be omitted
      refute "foo" in names
      assert length(results) == 1
    end

    @tag :tmp_dir
    test "respects limit and path scoping", %{tmp_dir: tmp_dir} do
      sub_dir = Path.join(tmp_dir, "nested/sub")
      File.mkdir_p!(sub_dir)

      # Create 10 functions
      functions =
        Enum.map_join(1..10, "\n", fn i ->
          "def func_#{i}(x), do: x + #{i}"
        end)

      File.write!(Path.join(sub_dir, "bulk.ex"), """
      defmodule Bulk.Module do
        #{functions}
      end
      """)

      # Limit search
      assert {:ok, limited} = ASTSearch.search(tmp_dir, %{path: "nested/sub"}, limit: 3)
      assert length(limited) == 3

      # Non-existent path returns path_not_found
      assert {:error, :path_not_found} = ASTSearch.search(tmp_dir, %{path: "non_existent_folder"})
    end
  end
end
