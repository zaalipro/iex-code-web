defmodule IexCode.HTTP do
  @moduledoc """
  Shared, bounded HTTP transport for application-owned `Req` calls.

  A single supervised Finch instance replaces Req's unbounded collection of
  option-specific Finch supervisors. Ordinary origins use the default pool;
  SSRF-protected requests use short-lived, user-managed pools keyed by the
  already validated IP address and TLS hostname. HTTP/1 pools and connections
  are reaped after an idle period, so researching many hosts does not leave one
  pool resident for every host for the lifetime of the VM.
  """

  @finch IexCode.HTTP.Finch
  @default_size 8
  @default_pool_idle_ms 60_000
  @default_connection_idle_ms 30_000

  @doc "Returns the supervised Finch child specification used by the app."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(overrides \\ []) when is_list(overrides) do
    options = pool_options(overrides)

    Finch.child_spec(
      name: @finch,
      pools: %{default: options}
    )
  end

  @doc "Runs a Req request through the shared bounded Finch instance."
  @spec request(keyword() | Req.Request.t()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(%Req.Request{} = request) do
    request
    |> Req.Request.merge_options(finch: [name: @finch])
    |> Req.request()
  end

  def request(options) when is_list(options) do
    options
    |> Keyword.put(:finch, name: @finch)
    |> Req.request()
  end

  @doc "Runs a Req GET through the shared bounded Finch instance."
  @spec get(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def get(url, options \\ []) when is_binary(url) and is_list(options) do
    request(Keyword.merge(options, method: :get, url: url))
  end

  @doc "Runs a Req POST through the shared bounded Finch instance."
  @spec post(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def post(url, options \\ []) when is_binary(url) and is_list(options) do
    request(Keyword.merge(options, method: :post, url: url))
  end

  @doc """
  Runs a request to a validated, pinned address without creating a Finch
  supervisor per hostname.

  `url` must already contain the resolved IP. `:connect_options` must contain
  the original `:hostname`, which remains the TLS SNI and certificate name.
  Callers remain responsible for URL validation and redirect validation.
  """
  @spec pinned_request(keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t() | atom()}
  def pinned_request(options) when is_list(options) do
    with {:ok, url} <- fetch_binary_url(options),
         {:ok, hostname, connect_options} <- take_hostname(options),
         {:ok, pool} <- pinned_pool(url, hostname),
         :ok <- start_pinned_pool(pool, connect_options) do
      options
      |> Keyword.delete(:connect_options)
      |> Keyword.put(:finch, name: @finch, pool_tag: pool.tag)
      |> Req.request()
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  def finch_name, do: @finch

  @doc false
  def pool_options(overrides \\ []) when is_list(overrides) do
    config = Application.get_env(:iex_code, :http_pool, [])

    [
      size: positive(Keyword.get(overrides, :size, config[:size]), @default_size),
      count: 1,
      protocols: [:http1],
      pool_max_idle_time:
        timeout(
          Keyword.get(overrides, :pool_max_idle_time, config[:pool_max_idle_time]),
          @default_pool_idle_ms
        ),
      conn_max_idle_time:
        timeout(
          Keyword.get(overrides, :conn_max_idle_time, config[:conn_max_idle_time]),
          @default_connection_idle_ms
        )
    ]
  end

  @doc false
  def pool_tag(hostname) when is_binary(hostname) do
    digest = :crypto.hash(:sha256, String.downcase(hostname))
    {:pinned_tls, binary_part(digest, 0, 12)}
  end

  defp fetch_binary_url(options) do
    case Keyword.get(options, :url) do
      url when is_binary(url) and byte_size(url) in 1..4_096 -> {:ok, url}
      _other -> {:error, :invalid_pinned_url}
    end
  end

  defp take_hostname(options) do
    connect_options = Keyword.get(options, :connect_options, [])

    case Keyword.get(connect_options, :hostname) do
      hostname when is_binary(hostname) and byte_size(hostname) in 1..253 ->
        {:ok, hostname, connect_options}

      _other ->
        {:error, :missing_pinned_hostname}
    end
  end

  defp pinned_pool(url, hostname) do
    pool = Finch.Pool.new(url, tag: pool_tag(hostname))

    if pool.scheme in [:http, :https] and is_binary(pool.host) do
      {:ok, pool}
    else
      {:error, :invalid_pinned_url}
    end
  rescue
    _error -> {:error, :invalid_pinned_url}
  end

  defp start_pinned_pool(pool, connect_options) do
    pool_options = pool_options()
    conn_opts = mint_connect_options(connect_options)

    Finch.start_pool(
      @finch,
      pool,
      Keyword.put(pool_options, :conn_opts, conn_opts)
    )
  end

  # Req's `:connect_options` are Mint options, while Finch expects them under
  # `:conn_opts`. Preserve the explicit hostname and place socket timeouts in
  # Mint's transport options just as Req.Finch does.
  defp mint_connect_options(options) do
    transport_options =
      options
      |> Keyword.get(:transport_opts, [])
      |> Keyword.put_new(:timeout, Keyword.get(options, :timeout, 15_000))

    options
    |> Keyword.take([:hostname, :proxy, :proxy_headers, :client_settings])
    |> Keyword.put(:transport_opts, transport_options)
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp timeout(:infinity, _default), do: :infinity
  defp timeout(value, _default) when is_integer(value) and value > 0, do: value
  defp timeout(_value, default), do: default
end
