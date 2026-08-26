defmodule IexCodeWeb.AdminAuth do
  @moduledoc """
  Authentication boundary for the single-owner web application.

  The application receives only a SHA-256 digest through the environment. The
  raw administrator token is accepted by the login form and is never persisted
  in the session. Rotating the configured digest invalidates existing sessions.
  """

  import Phoenix.LiveView, only: [redirect: 2]
  import Plug.Conn

  @hash_env "IEX_CODE_ADMIN_TOKEN_SHA256"
  @ttl_env "IEX_CODE_ADMIN_SESSION_TTL_SECONDS"
  @default_ttl_seconds 12 * 60 * 60
  @max_ttl_seconds 7 * 24 * 60 * 60
  @max_token_bytes 4_096
  @version_bytes 16

  @throttle_table :iex_code_web_admin_auth_throttle
  @throttle_window_seconds 60
  @throttle_attempt_limit 5
  @throttle_max_keys 8_192

  @session_version "admin_auth_version"
  @session_authenticated_at "admin_authenticated_at"
  @session_expires_at "admin_expires_at"

  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _hash}, configured_hash())

  @spec valid_token?(term()) :: boolean()
  def valid_token?(token) do
    {expected, configured?} =
      case configured_hash() do
        {:ok, hash} -> {hash, true}
        :error -> {String.duplicate("0", 64), false}
      end

    actual =
      if is_binary(token) and byte_size(token) <= @max_token_bytes do
        token
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
      else
        String.duplicate("f", 64)
      end

    matches? = Plug.Crypto.secure_compare(actual, expected)
    configured? and matches?
  end

  @doc "Returns whether another login attempt is permitted for this peer."
  @spec allow_attempt?(term()) :: boolean()
  def allow_attempt?(peer) do
    table = throttle_table()
    bucket = div(System.monotonic_time(:second), @throttle_window_seconds)
    key = {normalize_peer(peer), bucket}

    prune_throttle(table, bucket)

    if :ets.member(table, key) or :ets.info(table, :size) < @throttle_max_keys do
      count = :ets.update_counter(table, key, {2, 1}, {key, 0})
      count <= @throttle_attempt_limit
    else
      # Fail closed rather than allowing a distributed peer spray to turn the
      # bounded throttle table into unbounded memory growth.
      false
    end
  end

  @doc "Clears failed-attempt state after a successful authentication."
  @spec clear_attempts(term()) :: :ok
  def clear_attempts(peer) do
    table = throttle_table()
    normalized = normalize_peer(peer)
    :ets.match_delete(table, {{normalized, :_}, :_})
    :ok
  end

  @doc "Renews a Plug session with the minimal administrator claims."
  @spec sign_in(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_in(conn) do
    authenticated_at = System.system_time(:second)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@session_version, auth_version())
    |> put_session(@session_authenticated_at, authenticated_at)
    |> put_session(@session_expires_at, authenticated_at + session_ttl_seconds())
  end

  @doc "Drops the complete browser session."
  @spec sign_out(Plug.Conn.t()) :: Plug.Conn.t()
  def sign_out(conn) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
  end

  @spec authenticated?(Plug.Conn.t() | map()) :: boolean()
  def authenticated?(%Plug.Conn{} = conn), do: conn |> get_session() |> authenticated?()

  def authenticated?(session) when is_map(session) do
    with {:ok, version} <- auth_version_result(),
         ^version <- fetch_claim(session, @session_version),
         authenticated_at when is_integer(authenticated_at) <-
           fetch_claim(session, @session_authenticated_at),
         expires_at when is_integer(expires_at) <- fetch_claim(session, @session_expires_at),
         now <- System.system_time(:second),
         true <- authenticated_at <= now,
         true <- expires_at > now,
         true <- expires_at > authenticated_at,
         true <- expires_at - authenticated_at <= session_ttl_seconds() do
      true
    else
      _invalid -> false
    end
  end

  def authenticated?(_session), do: false

  @doc false
  def session_claims(authenticated_at \\ System.system_time(:second)) do
    %{
      @session_version => auth_version(),
      @session_authenticated_at => authenticated_at,
      @session_expires_at => authenticated_at + session_ttl_seconds()
    }
  end

  @doc "Shared LiveView authorization hook for both static and connected mounts."
  def on_mount(:require_admin, _params, session, socket) do
    if authenticated?(session) do
      socket =
        socket
        |> Phoenix.Component.assign(:current_scope, %{admin: true})
        |> schedule_live_expiry(fetch_claim(session, @session_expires_at))

      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  defp schedule_live_expiry(socket, expires_at) do
    if Phoenix.LiveView.connected?(socket) do
      timer_ref = make_ref()
      delay = max(expires_at - System.system_time(:second), 0) * 1_000
      Process.send_after(self(), {:admin_auth_expired, timer_ref}, delay)

      Phoenix.LiveView.attach_hook(
        socket,
        :admin_absolute_expiry,
        :handle_info,
        fn
          {:admin_auth_expired, ^timer_ref}, live_socket ->
            {:halt, redirect(live_socket, to: "/login")}

          _message, live_socket ->
            {:cont, live_socket}
        end
      )
    else
      socket
    end
  end

  defp configured_hash do
    case System.get_env(@hash_env) do
      <<hash::binary-size(64)>> ->
        if Regex.match?(~r/^[0-9a-f]{64}$/, hash), do: {:ok, hash}, else: :error

      _missing_or_invalid ->
        :error
    end
  end

  defp auth_version_result do
    case configured_hash() do
      {:ok, hash} -> {:ok, digest_version(hash)}
      :error -> :error
    end
  end

  defp auth_version do
    case auth_version_result() do
      {:ok, version} -> version
      :error -> "unconfigured"
    end
  end

  defp digest_version(hash) do
    hash
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, @version_bytes)
    |> Base.url_encode64(padding: false)
  end

  defp session_ttl_seconds do
    case Integer.parse(System.get_env(@ttl_env, "")) do
      {ttl, ""} when ttl > 0 -> min(ttl, @max_ttl_seconds)
      _invalid -> @default_ttl_seconds
    end
  end

  defp fetch_claim(session, @session_version),
    do: Map.get(session, @session_version, Map.get(session, :admin_auth_version))

  defp fetch_claim(session, @session_authenticated_at),
    do: Map.get(session, @session_authenticated_at, Map.get(session, :admin_authenticated_at))

  defp fetch_claim(session, @session_expires_at),
    do: Map.get(session, @session_expires_at, Map.get(session, :admin_expires_at))

  defp normalize_peer(peer) when is_tuple(peer) do
    case :inet.ntoa(peer) do
      address when is_list(address) -> List.to_string(address)
      _invalid -> "unknown"
    end
  end

  defp normalize_peer(peer) when is_binary(peer), do: String.slice(peer, 0, 128)
  defp normalize_peer(_peer), do: "unknown"

  defp prune_throttle(table, bucket) do
    :ets.select_delete(table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", bucket - 1}], [true]}])
    :ok
  end

  defp throttle_table do
    case :ets.whereis(@throttle_table) do
      :undefined -> start_throttle_owner()
      table -> table
    end
  end

  defp start_throttle_owner do
    :global.trans({__MODULE__, :throttle_table}, fn ->
      case :ets.whereis(@throttle_table) do
        :undefined ->
          parent = self()

          _pid =
            spawn(fn ->
              table =
                :ets.new(@throttle_table, [
                  :named_table,
                  :public,
                  :set,
                  read_concurrency: true,
                  write_concurrency: true
                ])

              send(parent, {:admin_auth_throttle_ready, table})
              throttle_owner_loop()
            end)

          receive do
            {:admin_auth_throttle_ready, table} -> table
          after
            1_000 -> :ets.whereis(@throttle_table)
          end

        table ->
          table
      end
    end)
  end

  defp throttle_owner_loop do
    receive do
      :stop -> :ok
      _message -> throttle_owner_loop()
    end
  end
end
