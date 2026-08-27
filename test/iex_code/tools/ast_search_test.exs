defmodule IexCode.Tools.ASTSearchTest do
  use ExUnit.Case, async: false
  alias IexCode.Tools
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

  describe "bounded workspace traversal" do
    @tag :tmp_dir
    test "stops at the file ceiling without recursive wildcard materialization", %{
      tmp_dir: root
    } do
      Enum.each(1..120, fn index ->
        File.write!(
          Path.join(root, "module_#{String.pad_leading(Integer.to_string(index), 3, "0")}.ex"),
          "defmodule Stress.Module#{index}, do: nil\n"
        )
      end)

      assert {:ok, metadata} =
               ASTSearch.search_with_metadata(root, %{type: :module},
                 max_files: 25,
                 max_entries: 80
               )

      assert metadata.truncated?
      assert :file_limit in metadata.truncation_reasons
      assert metadata.scanned_files == 25
      assert length(metadata.results) == 25
      assert metadata.scanned_entries <= 80
      assert metadata.scanned_bytes < 10_000
    end

    @tag :tmp_dir
    test "skips oversized files, bounds retained snippets, and continues useful search", %{
      tmp_dir: root
    } do
      huge =
        "defmodule AFirstHuge do\n  @payload \"#{String.duplicate("x", 80_000)}\"\nend\n"

      File.write!(Path.join(root, "a_huge.ex"), huge)
      File.write!(Path.join(root, "z_visible.ex"), "defmodule ZVisible, do: nil\n")

      assert {:ok, skipped} =
               ASTSearch.search_with_metadata(root, %{type: :module}, max_file_bytes: 4_096)

      assert skipped.truncated?
      assert :file_too_large in skipped.truncation_reasons
      assert skipped.skipped_large_files == 1
      assert Enum.any?(skipped.results, &(&1.name == "ZVisible"))
      refute Enum.any?(skipped.results, &(&1.name == "AFirstHuge"))

      assert {:ok, retained} =
               ASTSearch.search_with_metadata(Path.join(root, "a_huge.ex"), %{type: :module},
                 max_file_bytes: 100_000
               )

      assert [entry] = retained.results
      assert entry.name == "AFirstHuge"
      assert byte_size(entry.code) <= 4_100
      assert :erlang.external_size(entry) < 20_000
    end

    @tag :tmp_dir
    test "enforces aggregate source and result ceilings with explicit metadata", %{tmp_dir: root} do
      Enum.each(1..20, fn index ->
        functions =
          Enum.map_join(1..20, "\n", fn function_index ->
            "  def function_#{index}_#{function_index}, do: #{function_index}"
          end)

        File.write!(
          Path.join(root, "dense_#{String.pad_leading(Integer.to_string(index), 2, "0")}.ex"),
          "defmodule Dense#{index} do\n#{functions}\nend\n"
        )
      end)

      assert {:ok, byte_limited} =
               ASTSearch.search_with_metadata(root, %{type: :function},
                 max_total_bytes: 2_000,
                 max_file_bytes: 2_000
               )

      assert byte_limited.truncated?
      assert :byte_limit in byte_limited.truncation_reasons
      assert byte_limited.scanned_bytes <= 2_000

      assert {:ok, result_limited} =
               ASTSearch.search_with_metadata(root, %{type: :function},
                 limit: 400,
                 max_result_bytes: 2_000
               )

      assert result_limited.truncated?
      assert :result_byte_limit in result_limited.truncation_reasons
      assert :erlang.external_size(result_limited.results) < 3_000
    end

    @tag :tmp_dir
    test "does not follow directory or file symlinks", %{tmp_dir: root} do
      outside = root <> "-outside"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.ex"), "defmodule SymlinkSecret, do: nil\n")
      on_exit(fn -> File.rm_rf(outside) end)

      File.write!(Path.join(root, "visible.ex"), "defmodule VisibleReal, do: nil\n")
      File.ln_s!(outside, Path.join(root, "linked_directory"))
      File.ln_s!(Path.join(outside, "secret.ex"), Path.join(root, "linked_file.ex"))

      assert {:ok, metadata} = ASTSearch.search_with_metadata(root, %{type: :module})
      assert Enum.any?(metadata.results, &(&1.name == "VisibleReal"))
      refute Enum.any?(metadata.results, &(&1.name == "SymlinkSecret"))
    end

    @tag :tmp_dir
    test "preserves path-scoped matching and tool truncation guidance", %{tmp_dir: root} do
      nested = Path.join(root, "nested/sub")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "scoped.ex"), "defmodule ScopedModule, do: nil\n")

      assert {:ok, [scoped]} = ASTSearch.search(root, %{path: "nested/sub", type: :module})
      assert scoped.file == "nested/sub/scoped.ex"

      functions =
        Enum.map_join(1..550, "\n", fn index -> "  def function_#{index}, do: #{index}" end)

      File.write!(Path.join(root, "many.ex"), "defmodule Many do\n#{functions}\nend\n")

      assert {:ok, output} =
               Tools.execute("ast_search", %{"type" => "function", "path" => "many.ex"}, root)

      assert output =~ "AST search truncated: result_limit"
      assert output =~ "Narrow query/path"
    end
  end
end
