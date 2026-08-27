defmodule IexCode.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_path Path.expand("../../config/runtime.exs", __DIR__)
  @managed_env ~w(
    DATABASE_PATH SECRET_KEY_BASE PHX_HOST PHX_SCHEME PHX_PORT PORT POOL_SIZE
    PHX_SERVER IEX_CODE_BIND IEX_CODE_ALLOW_REMOTE IEX_CODE_ADMIN_TOKEN_SHA256
    IEX_CODE_WORKSPACE_ROOT IEX_CODE_DEFAULT_WORKSPACE DNS_CLUSTER_QUERY
    IEX_CODE_HTTP_POOL_SIZE IEX_CODE_HTTP_POOL_IDLE_MS IEX_CODE_HTTP_CONNECTION_IDLE_MS
    IEX_CODE_RESOURCE_PROFILE IEX_CODE_MEMORY_LIMIT_MIB IEX_CODE_TERMINAL_IDLE_TIMEOUT_MS
    SQLITE_CACHE_KIB SQLITE_TEMP_STORE
  )

  setup do
    previous = Map.new(@managed_env, &{&1, System.get_env(&1)})

    root =
      Path.join(
        System.tmp_dir!(),
        "iex-code-runtime-#{System.unique_integer([:positive, :monotonic])}"
      )

    default_workspace = Path.join(root, "default")
    File.mkdir_p!(default_workspace)

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_system_env(name, value) end)
      File.rm_rf(root)
    end)

    put_base_env(root)
    %{root: root, default_workspace: default_workspace}
  end

  test "builds an explicit HTTP public origin and validated server settings", %{
    root: root,
    default_workspace: default_workspace
  } do
    System.put_env("PHX_SCHEME", "http")
    System.put_env("PHX_HOST", "203.0.113.8")
    System.put_env("PHX_PORT", "8080")
    System.put_env("PORT", "4100")
    System.put_env("POOL_SIZE", "7")
    System.put_env("IEX_CODE_DEFAULT_WORKSPACE", "default")
    System.put_env("IEX_CODE_ALLOW_REMOTE", "true")
    System.put_env("IEX_CODE_ADMIN_TOKEN_SHA256", String.duplicate("a", 64))

    config = read_runtime!()
    app = Keyword.fetch!(config, :iex_code)
    endpoint = Keyword.fetch!(app, IexCodeWeb.Endpoint)
    repo = Keyword.fetch!(app, IexCode.Repo)

    assert endpoint[:url] == [host: "203.0.113.8", port: 8080, scheme: "http"]
    assert endpoint[:check_origin] == ["http://203.0.113.8:8080"]
    assert endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4100]
    assert repo[:pool_size] == 7
    assert app[:workspace_root] == canonical(root)
    assert app[:default_workspace_path] == canonical(default_workspace)
  end

  test "configures bounded shared HTTP pools from validated environment values" do
    System.put_env("IEX_CODE_HTTP_POOL_SIZE", "16")
    System.put_env("IEX_CODE_HTTP_POOL_IDLE_MS", "120000")
    System.put_env("IEX_CODE_HTTP_CONNECTION_IDLE_MS", "45000")

    config = read_runtime!()
    pool = config |> Keyword.fetch!(:iex_code) |> Keyword.fetch!(:http_pool)

    assert pool == [
             size: 16,
             pool_max_idle_time: 120_000,
             conn_max_idle_time: 45_000
           ]
  end

  test "rejects out-of-range shared HTTP pool values" do
    System.put_env("IEX_CODE_HTTP_POOL_SIZE", "65")

    assert_raise RuntimeError, ~r/IEX_CODE_HTTP_POOL_SIZE must be an integer/, &read_runtime!/0

    System.put_env("IEX_CODE_HTTP_POOL_SIZE", "8")
    System.put_env("IEX_CODE_HTTP_POOL_IDLE_MS", "999")

    assert_raise RuntimeError, ~r/IEX_CODE_HTTP_POOL_IDLE_MS must be an integer/, &read_runtime!/0

    System.put_env("IEX_CODE_HTTP_POOL_IDLE_MS", "60000")
    System.put_env("IEX_CODE_HTTP_CONNECTION_IDLE_MS", "forever")

    assert_raise RuntimeError,
                 ~r/IEX_CODE_HTTP_CONNECTION_IDLE_MS must be an integer/,
                 &read_runtime!/0
  end

  test "derives a safe governor tier from a custom memory envelope" do
    System.put_env("IEX_CODE_RESOURCE_PROFILE", "custom")

    for {memory_mib, expected} <- [{1_024, :compact}, {1_536, :balanced}, {2_560, :throughput}] do
      System.put_env("IEX_CODE_MEMORY_LIMIT_MIB", Integer.to_string(memory_mib))

      governor =
        read_runtime!()
        |> Keyword.fetch!(:iex_code)
        |> Keyword.fetch!(:resource_governor)

      assert governor[:profile] == expected
    end
  end

  test "explicit resource presets do not change with the envelope hint" do
    System.put_env("IEX_CODE_MEMORY_LIMIT_MIB", "1024")

    for {profile, expected} <-
          [{"compact", :compact}, {"balanced", :balanced}, {"throughput", :throughput}] do
      System.put_env("IEX_CODE_RESOURCE_PROFILE", profile)

      governor =
        read_runtime!()
        |> Keyword.fetch!(:iex_code)
        |> Keyword.fetch!(:resource_governor)

      assert governor[:profile] == expected
    end
  end

  test "uses the exact HTTPS domain as the LiveView origin" do
    System.put_env("PHX_HOST", "iex.llmotions.com")
    System.put_env("PHX_SCHEME", "https")
    System.delete_env("PHX_PORT")

    config = read_runtime!()
    endpoint = config |> Keyword.fetch!(:iex_code) |> Keyword.fetch!(IexCodeWeb.Endpoint)

    assert endpoint[:url] == [host: "iex.llmotions.com", port: 443, scheme: "https"]
    assert endpoint[:check_origin] == ["https://iex.llmotions.com"]
  end

  test "remote mode fails closed without a valid admin token hash" do
    System.put_env("IEX_CODE_ALLOW_REMOTE", "true")
    System.delete_env("IEX_CODE_ADMIN_TOKEN_SHA256")

    assert_raise RuntimeError, ~r/IEX_CODE_ADMIN_TOKEN_SHA256 is missing/, &read_runtime!/0

    System.put_env("IEX_CODE_ADMIN_TOKEN_SHA256", "ABC")

    assert_raise RuntimeError, ~r/must be a lowercase SHA-256 digest/, &read_runtime!/0
  end

  test "rejects malformed numeric and public URL configuration" do
    System.put_env("PORT", "4000oops")
    assert_raise RuntimeError, ~r/PORT must be an integer/, &read_runtime!/0

    System.put_env("PORT", "4000")
    System.put_env("PHX_HOST", "example.com:4000")
    assert_raise RuntimeError, ~r/PHX_HOST must not include a port/, &read_runtime!/0
  end

  test "requires an existing confined default workspace", %{root: root} do
    System.put_env("IEX_CODE_DEFAULT_WORKSPACE", Path.join(root, "missing"))
    assert_raise RuntimeError, ~r/must be an existing directory/, &read_runtime!/0
  end

  defp read_runtime!, do: Config.Reader.read!(@runtime_path, env: :prod)

  defp put_base_env(root) do
    Enum.each(@managed_env, &System.delete_env/1)
    System.put_env("DATABASE_PATH", Path.join(root, "iex_code.db"))
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
    System.put_env("PHX_HOST", "example.test")
    System.put_env("PHX_SCHEME", "https")
    System.put_env("PHX_SERVER", "false")
    System.put_env("IEX_CODE_WORKSPACE_ROOT", root)
  end

  defp canonical(path) do
    {:ok, canonical} = IexCode.WorkspacePath.resolve(path, "")
    canonical
  end

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
