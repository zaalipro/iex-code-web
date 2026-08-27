defmodule IexCode.HTTPTest do
  use ExUnit.Case, async: false

  alias IexCode.HTTP

  defmodule CaptureAdapter do
    @moduledoc false

    def run(request) do
      if owner = Process.get(:iex_code_http_test_owner) do
        send(owner, {:captured_request, request})
      end

      {request, %Req.Response{status: 200, body: "ok"}}
    end
  end

  setup do
    previous = Application.get_env(:iex_code, :http_pool)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:iex_code, :http_pool)
      else
        Application.put_env(:iex_code, :http_pool, previous)
      end
    end)

    :ok
  end

  test "pool options are bounded to one HTTP/1 shard and honor valid tuning" do
    Application.put_env(:iex_code, :http_pool,
      size: 4,
      pool_max_idle_time: 12_000,
      conn_max_idle_time: 6_000
    )

    assert HTTP.pool_options() == [
             size: 4,
             count: 1,
             protocols: [:http1],
             pool_max_idle_time: 12_000,
             conn_max_idle_time: 6_000
           ]

    assert HTTP.pool_options(size: 12, pool_max_idle_time: 90_000) == [
             size: 12,
             count: 1,
             protocols: [:http1],
             pool_max_idle_time: 90_000,
             conn_max_idle_time: 6_000
           ]
  end

  test "invalid tuning falls back to conservative defaults" do
    Application.put_env(:iex_code, :http_pool,
      size: 0,
      pool_max_idle_time: -1,
      conn_max_idle_time: "never"
    )

    assert HTTP.pool_options() == [
             size: 8,
             count: 1,
             protocols: [:http1],
             pool_max_idle_time: 60_000,
             conn_max_idle_time: 30_000
           ]
  end

  test "child spec starts the named shared Finch with bounded pools" do
    assert %{
             id: IexCode.HTTP.Finch,
             start: {Finch, :start_link, [options]}
           } = HTTP.child_spec(size: 3, pool_max_idle_time: 2_000, conn_max_idle_time: 1_000)

    assert options[:name] == HTTP.finch_name()

    assert options[:pools] == %{
             default: [
               size: 3,
               count: 1,
               protocols: [:http1],
               pool_max_idle_time: 2_000,
               conn_max_idle_time: 1_000
             ]
           }
  end

  test "list requests replace caller Finch configuration with the shared pool without network" do
    Process.put(:iex_code_http_test_owner, self())

    assert {:ok, %Req.Response{status: 200, body: "ok"}} =
             HTTP.request(
               url: "https://example.invalid/test",
               adapter: CaptureAdapter,
               finch: [name: AttackerFinch, pool_tag: :unbounded]
             )

    assert_receive {:captured_request, request}
    assert request.options[:finch] == [name: HTTP.finch_name()]
  end

  test "Req request structs are forced onto the shared pool without network" do
    Process.put(:iex_code_http_test_owner, self())

    request =
      Req.new(
        url: "https://example.invalid/test",
        adapter: CaptureAdapter,
        finch: [name: AttackerFinch, pool_tag: :unbounded]
      )

    assert {:ok, %Req.Response{status: 200}} = HTTP.request(request)
    assert_receive {:captured_request, captured}
    assert captured.options[:finch] == [name: HTTP.finch_name()]
  end

  test "application supervises exactly one named shared Finch instance" do
    assert is_pid(Process.whereis(HTTP.finch_name()))

    children = Supervisor.which_children(IexCode.Supervisor)

    assert [{IexCode.HTTP.Finch, pid, :worker, [Finch]}] =
             Enum.filter(children, fn {id, _pid, _type, _modules} ->
               id == IexCode.HTTP.Finch
             end)

    assert is_pid(pid)
  end

  test "pinned requests use a hostname-derived tag and remove raw connect options" do
    Process.put(:iex_code_http_test_owner, self())
    hostname = "Pinned.Example.com"
    url = "https://127.0.0.1:4443/path"
    pool = Finch.Pool.new(url, tag: HTTP.pool_tag(hostname))

    on_exit(fn ->
      _ = Finch.stop_pool(HTTP.finch_name(), pool)
    end)

    assert {:ok, %Req.Response{status: 200}} =
             HTTP.pinned_request(
               url: url,
               adapter: CaptureAdapter,
               connect_options: [
                 hostname: hostname,
                 timeout: 321,
                 transport_opts: [verify: :verify_peer]
               ]
             )

    assert_receive {:captured_request, request}
    assert request.options[:finch] == [name: HTTP.finch_name(), pool_tag: pool.tag]
    refute Map.has_key?(request.options, :connect_options)
    assert {:ok, pool_pid} = Finch.find_pool(HTTP.finch_name(), pool)
    assert is_pid(pool_pid)
  end

  test "pinned request requirements fail before pool or network activity" do
    assert HTTP.pinned_request([]) == {:error, :invalid_pinned_url}

    assert HTTP.pinned_request(url: "https://127.0.0.1/path") ==
             {:error, :missing_pinned_hostname}

    assert HTTP.pinned_request(
             url: "file:///tmp/secret",
             connect_options: [hostname: "example.com"]
           ) == {:error, :invalid_pinned_url}
  end

  test "pinned pool tags are stable, hostname-bound, case-insensitive, and opaque" do
    lower = HTTP.pool_tag("api.example.com")
    upper = HTTP.pool_tag("API.EXAMPLE.COM")
    other = HTTP.pool_tag("other.example.com")

    assert lower == upper
    refute lower == other
    assert {:pinned_tls, digest} = lower
    assert byte_size(digest) == 12
    refute inspect(lower) =~ "api.example.com"
  end
end
