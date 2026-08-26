defmodule IexCode.Tools.ASTSearchTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools.ASTSearch

  @sample_code """
  defmodule Sample.Math do
    @moduledoc "Math utility module"
    @default_factor 10

    @doc "Multiplies two numbers"
    @spec multiply(number(), number()) :: number()
    def multiply(a, b) when is_number(a) and is_number(b) do
      a * b * @default_factor
    end

    defp secret_calc(x), do: x * 2

    defmacro custom_macro(expr) do
      quote do: unquote(expr) + 1
    end

    @type num_pair :: {number(), number()}
    @callback compute(number()) :: number()
  end
  """

  describe "extract_symbols/2" do
    test "extracts modules, functions, macros, specs, docs, attributes, types, and callbacks" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "lib/sample/math.ex")

      assert Enum.any?(symbols, &(&1.type in [:module, :defmodule] and &1.name == "Sample.Math"))
      assert Enum.any?(symbols, &(&1.type == :moduledoc and &1.name == "@moduledoc"))
      assert Enum.any?(symbols, &(&1.type == :attribute and &1.name == "@default_factor"))
      assert Enum.any?(symbols, &(&1.type == :doc and &1.name == "@doc"))
      assert Enum.any?(symbols, &(&1.type == :spec and &1.name == "multiply" and &1.arity == 2))

      assert Enum.any?(
               symbols,
               &(&1.type in [:function, :def] and &1.name == "multiply" and &1.arity == 2 and
                   &1.visibility == :public)
             )

      assert Enum.any?(
               symbols,
               &(&1.type in [:function, :defp] and &1.name == "secret_calc" and &1.arity == 1 and
                   &1.visibility == :private)
             )

      assert Enum.any?(
               symbols,
               &(&1.type in [:macro, :defmacro] and &1.name == "custom_macro" and &1.arity == 1 and
                   &1.visibility == :public)
             )

      assert Enum.any?(symbols, &(&1.type == :type and &1.name == "num_pair"))

      assert Enum.any?(
               symbols,
               &(&1.type == :callback and &1.name == "compute" and &1.arity == 1)
             )
    end
  end

  describe "Query filtering" do
    test "filters symbols by function name and arity" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "math.ex")
      filtered = ASTSearch.Query.filter(symbols, %{function: "multiply", arity: 2})

      assert length(filtered) == 2
      types = Enum.map(filtered, & &1.type)
      assert :spec in types
      assert :def in types
    end

    test "filters symbols by type" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "math.ex")
      filtered = ASTSearch.Query.filter(symbols, %{type: :function})

      assert length(filtered) == 2
      names = Enum.map(filtered, & &1.name)
      assert "multiply" in names
      assert "secret_calc" in names
    end

    test "filters symbols by string query" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "math.ex")
      filtered = ASTSearch.Query.filter(symbols, "Math utility")

      assert length(filtered) >= 1
      assert Enum.any?(filtered, &(&1.type == :moduledoc))
      assert Enum.any?(filtered, &(&1.type == :defmodule))
    end
  end

  describe "search/3 and search_file/3" do
    @tag :tmp_dir
    test "searches directory files and returns matching symbols", %{tmp_dir: tmp_dir} do
      math_file = Path.join(tmp_dir, "math.ex")
      File.write!(math_file, @sample_code)

      assert {:ok, results} = ASTSearch.search(tmp_dir, %{function: "secret_calc"})
      assert length(results) == 1
      assert hd(results).name == "secret_calc"
      assert hd(results).visibility == :private

      assert {:ok, file_results} = ASTSearch.search_file(math_file, "custom_macro")
      assert length(file_results) == 1
      assert hd(file_results).type in [:macro, :defmacro]
    end

    test "format_results/2 formats output string" do
      {:ok, symbols} = ASTSearch.extract_symbols(@sample_code, "math.ex")
      formatted = ASTSearch.format_results(symbols, include_code: false)
      assert formatted =~ "math.ex:1 [module] Sample.Math"
      assert formatted =~ "math.ex:7 [function] Sample.Math.multiply/2"
      assert formatted =~ "secret_calc/1 (private)"
    end
  end
end
