import Config

parse_integer = fn name, default, range ->
  value = System.get_env(name) || to_string(default)

  case Integer.parse(value) do
    {integer, ""} ->
      if integer in range do
        integer
      else
        raise "environment variable #{name} must be an integer in #{inspect(range)}, got: #{inspect(value)}"
      end

    _ ->
      raise "environment variable #{name} must be an integer in #{inspect(range)}, got: #{inspect(value)}"
  end
end

parse_boolean = fn name, default ->
  value = System.get_env(name)

  case value do
    nil -> default
    value when value in ["1", "true", "TRUE"] -> true
    value when value in ["0", "false", "FALSE"] -> false
    _ -> raise "environment variable #{name} must be true or false, got: #{inspect(value)}"
  end
end

port = parse_integer.("PORT", 4000, 1..65_535)

if parse_boolean.("PHX_SERVER", false) do
  config :iex_code, IexCodeWeb.Endpoint, server: true
end

config :iex_code, IexCodeWeb.Endpoint, http: [port: port]

if config_env() == :prod do
  required = fn name ->
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: raise("environment variable #{name} must not be blank"), else: value

      _ ->
        raise "environment variable #{name} is missing"
    end
  end

  database_path = required.("DATABASE_PATH")
  secret_key_base = required.("SECRET_KEY_BASE")
  host = required.("PHX_HOST")
  workspace_root = required.("IEX_CODE_WORKSPACE_ROOT")
  allow_remote? = parse_boolean.("IEX_CODE_ALLOW_REMOTE", false)

  if not String.valid?(host) or
       String.contains?(host, [<<0>>, "/", "\\", "?", "#", "@", " ", "\t", "\r", "\n"]) do
    raise "environment variable PHX_HOST must be a hostname or IP address without a scheme or path"
  end

  if String.contains?(host, ":") and
       match?({:error, _reason}, :inet.parse_address(String.to_charlist(host))) do
    raise "environment variable PHX_HOST must not include a port"
  end

  scheme =
    case System.get_env("PHX_SCHEME", "https") |> String.trim() |> String.downcase() do
      scheme when scheme in ["http", "https"] ->
        scheme

      value ->
        raise "environment variable PHX_SCHEME must be http or https, got: #{inspect(value)}"
    end

  public_port_default = if scheme == "https", do: 443, else: port
  public_port = parse_integer.("PHX_PORT", public_port_default, 1..65_535)
  pool_size = parse_integer.("POOL_SIZE", 5, 1..50)

  terminal_idle_timeout_ms =
    parse_integer.("IEX_CODE_TERMINAL_IDLE_TIMEOUT_MS", 1_800_000, 1_000..86_400_000)

  http_pool_size = parse_integer.("IEX_CODE_HTTP_POOL_SIZE", 8, 1..64)

  http_pool_idle_ms =
    parse_integer.("IEX_CODE_HTTP_POOL_IDLE_MS", 60_000, 1_000..3_600_000)

  http_connection_idle_ms =
    parse_integer.("IEX_CODE_HTTP_CONNECTION_IDLE_MS", 30_000, 1_000..3_600_000)

  memory_limit_mib = parse_integer.("IEX_CODE_MEMORY_LIMIT_MIB", 2_048, 256..65_536)

  resource_profile =
    case System.get_env("IEX_CODE_RESOURCE_PROFILE", "balanced") do
      "compact" ->
        :compact

      "balanced" ->
        :balanced

      "throughput" ->
        :throughput

      # A custom deployment keeps its explicit Docker envelope while choosing
      # governor headroom from the nearest conservative preset. Treating every
      # custom limit as balanced can make the 512 MiB build class impossible to
      # admit on an otherwise healthy custom 1 GiB installation.
      "custom" ->
        cond do
          memory_limit_mib <= 1_024 -> :compact
          memory_limit_mib <= 2_048 -> :balanced
          true -> :throughput
        end

      value ->
        raise "IEX_CODE_RESOURCE_PROFILE is invalid: #{inspect(value)}"
    end

  sqlite_cache_kib = parse_integer.("SQLITE_CACHE_KIB", 16_384, 1_024..262_144)

  sqlite_temp_store =
    case System.get_env("SQLITE_TEMP_STORE", "file") |> String.downcase() do
      "default" -> :default
      "file" -> :file
      "memory" -> :memory
      value -> raise "SQLITE_TEMP_STORE must be default, file, or memory, got: #{inspect(value)}"
    end

  bind_ip =
    case System.get_env("IEX_CODE_BIND") do
      value when value in [nil, ""] ->
        {127, 0, 0, 1}

      ip ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, address} ->
            address

          {:error, _reason} ->
            raise "environment variable IEX_CODE_BIND is not a valid IP address"
        end
    end

  if allow_remote? do
    auth_hash = required.("IEX_CODE_ADMIN_TOKEN_SHA256")

    if not Regex.match?(~r/^[0-9a-f]{64}$/, auth_hash) do
      raise "environment variable IEX_CODE_ADMIN_TOKEN_SHA256 must be a lowercase SHA-256 digest when remote access is enabled"
    end
  end

  if not String.valid?(workspace_root) or String.contains?(workspace_root, <<0>>) do
    raise "environment variable IEX_CODE_WORKSPACE_ROOT must be a valid UTF-8 path"
  end

  workspace_root = Path.expand(workspace_root)

  workspace_root =
    case IexCode.WorkspacePath.resolve(workspace_root, "") do
      {:ok, canonical} ->
        canonical

      {:error, reason} ->
        raise "IEX_CODE_WORKSPACE_ROOT must be an existing directory: #{inspect(reason)}"
    end

  default_workspace =
    case System.get_env("IEX_CODE_DEFAULT_WORKSPACE") do
      value when value in [nil, ""] -> workspace_root
      value -> if Path.type(value) == :absolute, do: value, else: Path.join(workspace_root, value)
    end

  default_workspace =
    case IexCode.WorkspacePath.resolve(workspace_root, default_workspace) do
      {:ok, canonical} when is_binary(canonical) ->
        if File.dir?(canonical),
          do: canonical,
          else: raise("IEX_CODE_DEFAULT_WORKSPACE must be an existing directory")

      {:error, reason} ->
        raise "IEX_CODE_DEFAULT_WORKSPACE is outside the workspace root or invalid: #{inspect(reason)}"
    end

  public_url = URI.to_string(%URI{scheme: scheme, host: host, port: public_port})

  config :iex_code,
    workspace_root: workspace_root,
    default_workspace_path: default_workspace,
    terminal_idle_timeout_ms: terminal_idle_timeout_ms,
    dns_cluster_query: System.get_env("DNS_CLUSTER_QUERY")

  config :iex_code, :resource_governor, profile: resource_profile

  config :iex_code, :memory_guardrail, memory_limit_bytes: memory_limit_mib * 1_048_576

  config :iex_code, :http_pool,
    size: http_pool_size,
    pool_max_idle_time: http_pool_idle_ms,
    conn_max_idle_time: http_connection_idle_ms

  config :iex_code, IexCode.Repo,
    database: database_path,
    pool_size: pool_size,
    cache_size: -sqlite_cache_kib,
    temp_store: sqlite_temp_store,
    busy_timeout: 5_000,
    journal_mode: :wal

  config :iex_code, IexCodeWeb.Endpoint,
    url: [host: host, port: public_port, scheme: scheme],
    http: [ip: bind_ip, port: port],
    check_origin: [public_url],
    secret_key_base: secret_key_base
end
