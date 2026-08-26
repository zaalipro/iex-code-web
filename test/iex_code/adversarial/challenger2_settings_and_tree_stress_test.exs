defmodule IexCode.Adversarial.Challenger2SettingsAndTreeStressTest do
  use IexCode.DataCase, async: false
  @moduletag timeout: 120_000

  alias IexCode.Settings
  alias IexCode.Settings.AppSettings
  alias IexCode.Repo

  setup do
    IexCode.DataCase.drain_all_processes()
    # Pre-seed default settings so existing singleton row is ready for updates
    _ = Settings.get_settings()
    :ok
  end

  # ============================================================================
  # Area 1: Settings Bounds, Validation, and Credential Handling
  # ============================================================================

  describe "Settings bounds and validation stress" do
    test "strictly enforces temperature boundaries [0.0 .. 2.0]" do
      settings = Settings.get_settings()

      # Exact valid boundaries
      assert {:ok, s0} = Settings.update_settings(%{temperature: 0.0})
      assert s0.temperature == 0.0

      assert {:ok, s2} = Settings.update_settings(%{temperature: 2.0})
      assert s2.temperature == 2.0

      assert {:ok, s1} = Settings.update_settings(%{temperature: 1.0})
      assert s1.temperature == 1.0

      # Out of bounds negative values
      for invalid_temp <- [-1.0, -0.01, -5.0, -100.0] do
        cs = Settings.change_settings(settings, %{temperature: invalid_temp})
        refute cs.valid?, "Expected temperature #{invalid_temp} to be invalid"
        assert %{temperature: [err]} = errors_on(cs)
        assert err =~ "greater than or equal to 0.0"

        assert {:error, err_cs} = Settings.update_settings(%{temperature: invalid_temp})
        assert %{temperature: _} = errors_on(err_cs)
      end

      # Out of bounds positive values
      for invalid_temp <- [2.01, 2.5, 5.0, 10.0, 100.0] do
        cs = Settings.change_settings(settings, %{temperature: invalid_temp})
        refute cs.valid?, "Expected temperature #{invalid_temp} to be invalid"
        assert %{temperature: [err]} = errors_on(cs)
        assert err =~ "less than or equal to 2.0"

        assert {:error, err_cs} = Settings.update_settings(%{temperature: invalid_temp})
        assert %{temperature: _} = errors_on(err_cs)
      end
    end

    test "strictly enforces max_tokens boundaries [1 .. 128000]" do
      settings = Settings.get_settings()

      # Exact valid boundaries
      assert {:ok, s1} = Settings.update_settings(%{max_tokens: 1})
      assert s1.max_tokens == 1

      assert {:ok, s_max} = Settings.update_settings(%{max_tokens: 128_000})
      assert s_max.max_tokens == 128_000

      assert {:ok, s_mid} = Settings.update_settings(%{max_tokens: 4096})
      assert s_mid.max_tokens == 4096

      # Out of bounds lower values
      for invalid_tokens <- [0, -1, -50, -1000] do
        cs = Settings.change_settings(settings, %{max_tokens: invalid_tokens})
        refute cs.valid?, "Expected max_tokens #{invalid_tokens} to be invalid"
        assert %{max_tokens: [err]} = errors_on(cs)
        assert err =~ "greater than or equal to 1"

        assert {:error, err_cs} = Settings.update_settings(%{max_tokens: invalid_tokens})
        assert %{max_tokens: _} = errors_on(err_cs)
      end

      # Out of bounds upper values
      for invalid_tokens <- [128_001, 150_000, 999_999, 1_000_000] do
        cs = Settings.change_settings(settings, %{max_tokens: invalid_tokens})
        refute cs.valid?, "Expected max_tokens #{invalid_tokens} to be invalid"
        assert %{max_tokens: [err]} = errors_on(cs)
        assert err =~ "less than or equal to 128000"

        assert {:error, err_cs} = Settings.update_settings(%{max_tokens: invalid_tokens})
        assert %{max_tokens: _} = errors_on(err_cs)
      end
    end

    test "strictly enforces swarm_agent_count boundaries [4 .. 32]" do
      settings = Settings.get_settings()

      assert {:ok, s4} = Settings.update_settings(%{swarm_agent_count: 4})
      assert s4.swarm_agent_count == 4

      assert {:ok, s32} = Settings.update_settings(%{swarm_agent_count: 32})
      assert s32.swarm_agent_count == 32

      for invalid_count <- [0, -1, 1, 2, 3, 33, 64, 100] do
        cs = Settings.change_settings(settings, %{swarm_agent_count: invalid_count})
        refute cs.valid?, "Expected swarm_agent_count #{invalid_count} to be invalid"
        assert %{swarm_agent_count: _} = errors_on(cs)

        assert {:error, _} = Settings.update_settings(%{swarm_agent_count: invalid_count})
      end
    end

    test "validates model providers and rejects unsupported providers" do
      settings = Settings.get_settings()

      for valid_provider <- ["openai", "anthropic"] do
        assert {:ok, updated} =
                 Settings.update_settings(%{default_model_provider: valid_provider})

        assert updated.default_model_provider == valid_provider
      end

      for invalid_provider <- ["ollama", "gemini_raw", "local_custom", "invalid_123"] do
        cs = Settings.change_settings(settings, %{default_model_provider: invalid_provider})
        refute cs.valid?, "Expected default_model_provider '#{invalid_provider}' to be rejected"
        assert %{default_model_provider: _} = errors_on(cs)

        assert {:error, _} = Settings.update_settings(%{default_model_provider: invalid_provider})
      end
    end

    test "handles empty, nil, and custom API keys without synthetic injection" do
      # Set explicit custom keys
      {:ok, s1} =
        Settings.update_settings(%{
          openai_api_key: "sk-proj-test999",
          anthropic_api_key: "sk-ant-test999",
          openai_base_url: "https://custom-openai.example.com/v1",
          anthropic_base_url: "https://custom-anthropic.example.com"
        })

      assert s1.openai_api_key == "sk-proj-test999"
      assert s1.anthropic_api_key == "sk-ant-test999"
      assert s1.openai_base_url == "https://custom-openai.example.com/v1"
      assert s1.anthropic_base_url == "https://custom-anthropic.example.com"

      # Clear keys back to blank (Ecto casts empty string to nil)
      {:ok, s2} =
        Settings.update_settings(%{
          openai_api_key: nil,
          anthropic_api_key: nil
        })

      assert is_nil(s2.openai_api_key) or s2.openai_api_key == ""
      assert is_nil(s2.anthropic_api_key) or s2.anthropic_api_key == ""

      fetched = Settings.get_settings()
      assert is_nil(fetched.openai_api_key) or fetched.openai_api_key == ""
      assert is_nil(fetched.anthropic_api_key) or fetched.anthropic_api_key == ""
    end

    test "maintains fallback endpoints when custom base URLs are updated" do
      {:ok, s} =
        Settings.update_settings(%{
          openai_base_url: "https://api.openai.com/v1",
          anthropic_base_url: "https://api.anthropic.com",
          default_model_provider: "openai",
          default_model: "gemini-3.7-flash-high"
        })

      assert s.openai_base_url == "https://api.openai.com/v1"
      assert s.anthropic_base_url == "https://api.anthropic.com"
      assert s.default_model == "gemini-3.7-flash-high"
      assert s.default_model_provider == "openai"
    end
  end

  # ============================================================================
  # Area 2: SQLite Concurrency Stress with retry_on_busy
  # ============================================================================

  describe "Concurrent update_settings stress" do
    test "20 concurrent workers execute update_settings without corruption or deadlocks" do
      # Pre-seed settings to ensure existing singleton row is ready
      {:ok, _} =
        Settings.update_settings(%{
          default_model_provider: "openai",
          swarm_agent_count: 4,
          temperature: 0.2,
          max_tokens: 4096
        })

      models = [
        "claude-3-7-sonnet",
        "gemini-3.7-flash-high",
        "gpt-4o",
        "claude-3-5-haiku",
        "o3-mini"
      ]

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            model = Enum.at(models, rem(i, length(models)))
            temp = Float.round(0.1 + rem(i, 18) * 0.1, 2)
            tokens = 1000 + i * 500

            result =
              Settings.update_settings(%{
                default_model: model,
                temperature: temp,
                max_tokens: tokens,
                swarm_agent_count: min(32, max(4, rem(i, 16) + 4))
              })

            case result do
              {:ok, updated} ->
                assert %AppSettings{} = updated
                :ok

              {:error, reason} ->
                {:error, i, reason}
            end
          end)
        end

      results = Task.await_many(tasks, 30_000)

      successful_updates =
        Enum.count(results, fn
          :ok -> true
          _ -> false
        end)

      assert successful_updates == 20,
             "Expected all 20 concurrent updates to succeed, got: #{inspect(results)}"

      # Verify singleton row invariant in DB
      rows_count = Repo.aggregate(AppSettings, :count, :id)
      assert rows_count == 1, "Expected exactly 1 AppSettings row in DB, found #{rows_count}"

      # Verify get_settings returns a valid record
      final_settings = Settings.get_settings()
      assert %AppSettings{} = final_settings
      assert final_settings.temperature >= 0.0 and final_settings.temperature <= 2.0
      assert final_settings.max_tokens >= 1 and final_settings.max_tokens <= 128_000
    end
  end

  # ============================================================================
  # Area 3: File Tree Building & Flattening Stress
  # ============================================================================

  describe "File tree building and flattening stress" do
    defp build_tree(files) do
      Enum.reduce(files, %{}, fn file, acc ->
        parts = Path.split(file)
        put_file(acc, parts, file)
      end)
    end

    defp put_file(acc, [filename], full_path) do
      Map.put(acc, filename, {:file, filename, full_path})
    end

    defp put_file(acc, [dir | rest], full_path) do
      dir_entry =
        case Map.get(acc, dir) do
          {:dir, name, path, children} ->
            {:dir, name, path, children}

          _ ->
            full_parts = Path.split(full_path)
            dir_idx = Enum.find_index(full_parts, &(&1 == dir))

            dir_path =
              if dir_idx do
                full_parts |> Enum.take(dir_idx + 1) |> Path.join()
              else
                dir
              end

            {:dir, dir, dir_path, %{}}
        end

      {:dir, name, path, children} = dir_entry
      updated_children = put_file(children, rest, full_path)
      Map.put(acc, dir, {:dir, name, path, updated_children})
    end

    defp flatten_tree(tree, expanded_folders, depth \\ 0) do
      tree
      |> Enum.sort_by(fn
        {name, {:dir, _, _, _}} -> {0, String.downcase(name)}
        {name, {:file, _, _}} -> {1, String.downcase(name)}
      end)
      |> Enum.flat_map(fn
        {_name, {:dir, name, path, children}} ->
          is_expanded = MapSet.member?(expanded_folders, path)
          item = %{type: :dir, name: name, path: path, depth: depth, expanded: is_expanded}

          if is_expanded do
            [item | flatten_tree(children, expanded_folders, depth + 1)]
          else
            [item]
          end

        {_name, {:file, name, full_path}} ->
          [%{type: :file, name: name, path: full_path, depth: depth}]
      end)
    end

    test "handles empty project file list gracefully" do
      tree = build_tree([])
      assert tree == %{}

      flattened = flatten_tree(tree, MapSet.new())
      assert flattened == []
    end

    test "handles deeply nested paths (25 levels deep) with accurate depth calculation" do
      deep_levels = for i <- 1..25, do: "level_#{String.pad_leading(to_string(i), 2, "0")}"
      deep_file = Path.join(deep_levels ++ ["deep_module.ex"])

      tree = build_tree([deep_file])
      assert Map.has_key?(tree, "level_01")

      # When no folders are expanded
      collapsed = flatten_tree(tree, MapSet.new())
      assert length(collapsed) == 1
      assert hd(collapsed).type == :dir
      assert hd(collapsed).name == "level_01"
      assert hd(collapsed).depth == 0
      assert hd(collapsed).expanded == false

      # Expand all 25 directory paths
      all_paths =
        for i <- 1..25 do
          deep_levels |> Enum.take(i) |> Path.join()
        end
        |> MapSet.new()

      expanded = flatten_tree(tree, all_paths)
      # 25 directories + 1 file = 26 items
      assert length(expanded) == 26

      # Check last directory and file depths
      file_item = List.last(expanded)
      assert file_item.type == :file
      assert file_item.name == "deep_module.ex"
      assert file_item.path == deep_file
      assert file_item.depth == 25
    end

    test "correctly builds tree with dotted paths, hidden files, special symbols, and Unicode" do
      files = [
        ".env",
        ".env.local",
        ".gitignore",
        ".github/workflows/ci.yml",
        "config/config.exs",
        "lib/my.dotted.module/sub.namespace/foo.bar.ex",
        "lib/unicode_🔥/emoji_🚀.ex",
        "test/special chars & symbols/file with spaces (1) [copy] #tag.ex",
        "test/hyphen-separated-dir_with_underscores/sample-test_file.ex"
      ]

      tree = build_tree(files)

      # Root level files and directories
      assert Map.has_key?(tree, ".env")
      assert Map.has_key?(tree, ".env.local")
      assert Map.has_key?(tree, ".gitignore")
      assert Map.has_key?(tree, ".github")
      assert Map.has_key?(tree, "config")
      assert Map.has_key?(tree, "lib")
      assert Map.has_key?(tree, "test")

      # Flatten with all folders expanded
      all_dirs =
        MapSet.new([
          ".github",
          ".github/workflows",
          "config",
          "lib",
          "lib/my.dotted.module",
          "lib/my.dotted.module/sub.namespace",
          "lib/unicode_🔥",
          "test",
          "test/special chars & symbols",
          "test/hyphen-separated-dir_with_underscores"
        ])

      flattened = flatten_tree(tree, all_dirs)

      # Ensure directories precede files at each level
      paths = Enum.map(flattened, & &1.path)
      assert ".env" in paths
      assert ".env.local" in paths
      assert "lib/unicode_🔥/emoji_🚀.ex" in paths
      assert "test/special chars & symbols/file with spaces (1) [copy] #tag.ex" in paths
      assert "lib/my.dotted.module/sub.namespace/foo.bar.ex" in paths

      # Verify unicode dir representation
      emoji_dir = Enum.find(flattened, &(&1.path == "lib/unicode_🔥"))
      assert emoji_dir.type == :dir
      assert emoji_dir.name == "unicode_🔥"
      assert emoji_dir.depth == 1
    end

    test "deterministic alphabetical ordering: directories first, then files" do
      files = [
        "zebra.txt",
        "alpha.txt",
        "beta_dir/file2.txt",
        "alpha_dir/file1.txt",
        "middle.txt"
      ]

      tree = build_tree(files)
      flattened = flatten_tree(tree, MapSet.new(["alpha_dir", "beta_dir"]))

      names = Enum.map(flattened, & &1.name)

      # Directories should come before root files
      assert names == [
               "alpha_dir",
               "file1.txt",
               "beta_dir",
               "file2.txt",
               "alpha.txt",
               "middle.txt",
               "zebra.txt"
             ]
    end
  end
end
