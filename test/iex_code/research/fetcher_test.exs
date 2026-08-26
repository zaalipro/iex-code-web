defmodule IexCode.Research.FetcherTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.Fetcher

  @public {93, 184, 216, 34}

  test "pins requests and extracts readable HTML" do
    parent = self()

    request = fn url, opts ->
      send(parent, {:request, url, opts})

      {:ok,
       %{
         status: 200,
         headers: %{"content-type" => ["text/html; charset=utf-8"]},
         body:
           "<html><body><main><h1>Hello</h1><script>bad()</script><p>Useful text</p></main></body></html>"
       }}
    end

    assert {:ok, result} = Fetcher.fetch("https://source.test/report", fetch_opts(request))
    assert result.text == "Hello Useful text"
    assert result.content_type == "text/html"
    assert result.redirects == []

    assert_receive {:request, "https://93.184.216.34/report", opts}
    assert opts[:redirect] == false
    assert opts[:retry] == false
    assert opts[:receive_timeout] == 250
    assert opts[:connect_options][:hostname] == "source.test"
    assert is_function(opts[:into], 2)
  end

  test "follows a relative redirect and revalidates every host" do
    parent = self()

    resolver = fn host ->
      send(parent, {:resolved, host})
      {:ok, [@public]}
    end

    request = fn url, _opts ->
      case URI.parse(url).path do
        "/old" ->
          {:ok, %{status: 302, headers: %{"location" => ["https://next.test/new"]}, body: ""}}

        "/new" ->
          {:ok,
           %{status: 200, headers: %{"content-type" => ["text/plain"]}, body: " final\n text "}}
      end
    end

    assert {:ok, result} =
             Fetcher.fetch("https://first.test/old",
               resolver: resolver,
               request: request,
               timeout: 250
             )

    assert result.text == "final text"
    assert result.url == "https://next.test/new"
    assert result.redirects == ["https://first.test/old"]
    assert_receive {:resolved, "first.test"}
    assert_receive {:resolved, "next.test"}
  end

  test "blocks an internal redirect before issuing its request" do
    parent = self()

    resolver = fn
      "public.test" -> {:ok, [@public]}
      "internal.test" -> {:ok, [{10, 0, 0, 8}]}
    end

    request = fn _url, _opts ->
      send(parent, :requested)

      {:ok, %{status: 302, headers: %{"location" => ["http://internal.test/secrets"]}, body: ""}}
    end

    assert {:error, :non_public_address} =
             Fetcher.fetch("https://public.test", resolver: resolver, request: request)

    assert_receive :requested
    refute_receive :requested
  end

  test "enforces redirect, body, content type, timeout and JSON constraints" do
    resolver = fn _ -> {:ok, [@public]} end

    redirect = fn _url, _opts ->
      {:ok, %{status: 302, headers: %{"location" => ["/again"]}, body: ""}}
    end

    assert {:error, :too_many_redirects} =
             Fetcher.fetch("https://loop.test",
               resolver: resolver,
               request: redirect,
               max_redirects: 1
             )

    oversized = response("text/plain", "12345")

    assert {:error, :body_too_large} =
             Fetcher.fetch(
               "https://large.test",
               request_opts(oversized, resolver) ++ [max_body_bytes: 4]
             )

    binary = response("application/octet-stream", "abc")

    assert {:error, {:unsupported_content_type, "application/octet-stream"}} =
             Fetcher.fetch("https://binary.test", request_opts(binary, resolver))

    invalid_json = response("application/json", "not json")

    assert {:error, {:invalid_json, _}} =
             Fetcher.fetch("https://json.test", request_opts(invalid_json, resolver))

    assert {:error, :invalid_timeout} = Fetcher.fetch("https://source.test", timeout: 60_001)
  end

  test "streaming collector stops a response once its body cap is crossed" do
    request = fn _url, opts ->
      request = Req.new()

      response =
        Req.Response.new(status: 200, headers: %{"content-type" => ["text/plain"]})

      into = opts[:into]
      assert {:cont, {request, response}} = into.({:data, "123"}, {request, response})
      assert {:halt, {_request, response}} = into.({:data, "456"}, {request, response})
      {:ok, response}
    end

    assert {:error, :body_too_large} =
             Fetcher.fetch("https://stream.test", fetch_opts(request) ++ [max_body_bytes: 5])
  end

  test "applies a total deadline to an injected request" do
    request = fn _url, _opts ->
      receive do
        :never -> {:error, :unexpected}
      after
        5_000 -> {:error, :late}
      end
    end

    assert {:error, {:request_failed, :timeout}} =
             Fetcher.fetch("https://slow.test", fetch_opts(request) ++ [timeout: 10])
  end

  defp fetch_opts(request) do
    [resolver: fn _ -> {:ok, [@public]} end, request: request, timeout: 250]
  end

  defp response(type, body),
    do: %{status: 200, headers: %{"content-type" => [type]}, body: body}

  defp request_opts(response, resolver) do
    [resolver: resolver, request: fn _url, _opts -> {:ok, response} end]
  end
end
