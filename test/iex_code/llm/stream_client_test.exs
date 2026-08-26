defmodule IexCode.LLM.StreamClientTest do
  use ExUnit.Case, async: false
  alias IexCode.LLM.StreamClient

  defmodule SecretCallbackError do
    defexception [:message, :context]
  end

  defmodule MockStreamPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/openai/stream" ->
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> send_chunked(200)

          chunk1 =
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]},\"finish_reason\":null}]}\n\n"

          chunk2 =
            "data: {\"choices\":[{\"delta\":{\"content\":\"world!\",\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\" \\\"test.ex\\\"}\"}}]},\"finish_reason\":null}]}\n\n"

          chunk3 = "data: [DONE]\n\n"

          {:ok, conn} = chunk(conn, chunk1)
          {:ok, conn} = chunk(conn, chunk2)
          {:ok, conn} = chunk(conn, chunk3)
          conn

        "/openai/usage" ->
          {:ok, body, conn} = read_body(conn)
          request = Jason.decode!(body)
          send(Process.whereis(:stream_usage_test), {:stream_request, request})

          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> send_chunked(200)

          {:ok, conn} =
            chunk(
              conn,
              "data: {\"choices\":[{\"delta\":{\"content\":\"Measured\"},\"finish_reason\":null}]}\n\n"
            )

          {:ok, conn} =
            chunk(
              conn,
              "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":8,\"total_tokens\":20}}\n\n"
            )

          {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
          conn

        "/openai/usage-total-only" ->
          {:ok, body, conn} = read_body(conn)
          request = Jason.decode!(body)
          send(Process.whereis(:stream_total_usage_test), {:stream_request, request})

          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> send_chunked(200)

          {:ok, conn} =
            chunk(
              conn,
              "data: {\"choices\":[{\"delta\":{\"content\":\"Total only\"},\"finish_reason\":null}]}\n\n"
            )

          {:ok, conn} =
            chunk(conn, "data: {\"choices\":[],\"usage\":{\"total_tokens\":50}}\n\n")

          {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
          conn

        "/anthropic/stream" ->
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> send_chunked(200)

          chunk1 =
            "event: content_block_start\ndata: {\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_ant\",\"name\":\"write_file\"}}\n\n"

          chunk2 =
            "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\": \\\"foo.ex\\\"}\"}}\n\n"

          chunk3 =
            "event: content_block_delta\ndata: {\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Written!\"}}\n\n"

          chunk4 = "event: message_stop\ndata: {}\n\n"

          {:ok, conn} = chunk(conn, chunk1)
          {:ok, conn} = chunk(conn, chunk2)
          {:ok, conn} = chunk(conn, chunk3)
          {:ok, conn} = chunk(conn, chunk4)
          conn

        "/error/500" ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(500, "{\"error\": \"Internal Server Error\"}")

        "/error/oversized-secret" ->
          secret = conn |> get_req_header("authorization") |> List.first()

          conn
          |> put_resp_header("content-type", "text/plain")
          |> send_resp(500, String.duplicate("upstream echoed #{secret}\n", 5_000))

        "/error/small-secret" ->
          secret = conn |> get_req_header("authorization") |> List.first()

          conn
          |> put_resp_header("content-type", "text/plain")
          |> send_resp(500, "upstream echoed #{secret}")

        "/error/cutoff-secret" ->
          secret = conn |> get_req_header("authorization") |> List.first()

          conn
          |> put_resp_header("content-type", "text/plain")
          |> send_resp(500, String.duplicate("x", 63_995) <> secret <> " trailing bytes")

        "/openai/oversized-success" ->
          conn =
            conn
            |> put_resp_header("content-type", "text/event-stream")
            |> send_chunked(200)

          {:ok, conn} =
            chunk(
              conn,
              "data: " <>
                Jason.encode!(%{
                  "choices" => [
                    %{"delta" => %{"content" => String.duplicate("x", 2_000_001)}}
                  ]
                }) <>
                "\n\n"
            )

          conn
      end
    end
  end

  setup_all do
    server =
      start_supervised!(
        {Bandit, plug: MockStreamPlug, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {:ok, %{port: port, server: server}}
  end

  describe "StreamClient.stream/2" do
    test "streams OpenAI chunks, emits callbacks, and accumulates tool calls", %{port: port} do
      {:ok, chunks_agent} = Agent.start_link(fn -> [] end)
      on_chunk = fn chunk -> Agent.update(chunks_agent, fn l -> [chunk | l] end) end

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/openai/stream",
        body: %{"model" => "gpt-4o", "messages" => []}
      ]

      assert {:ok, resp} = StreamClient.stream(request_opts, on_chunk)
      chunks = Agent.get(chunks_agent, & &1) |> Enum.reverse()
      Agent.stop(chunks_agent)

      # Callbacks received
      assert chunks == ["Hello ", "world!"]

      # Final message text accumulated
      assert resp.text == "Hello world!"

      # Tool call accumulated and decoded
      assert length(resp.tool_calls) == 1
      [tc] = resp.tool_calls
      assert tc.id == "call_1"
      assert tc.name == "read_file"
      assert tc.args == %{"path" => "test.ex"}
    end

    test "streams Anthropic chunks and parses input json delta", %{port: port} do
      {:ok, chunks_agent} = Agent.start_link(fn -> [] end)
      on_chunk = fn chunk -> Agent.update(chunks_agent, fn l -> [chunk | l] end) end

      request_opts = [
        provider: "anthropic",
        url: "http://127.0.0.1:#{port}/anthropic/stream",
        body: %{"model" => "claude-3-7-sonnet", "messages" => []}
      ]

      assert {:ok, resp} = StreamClient.stream(request_opts, on_chunk)
      chunks = Agent.get(chunks_agent, & &1)
      Agent.stop(chunks_agent)

      assert chunks == ["Written!"]
      assert resp.text == "Written!"

      assert length(resp.tool_calls) == 1
      [tc] = resp.tool_calls
      assert tc.id == "call_ant"
      assert tc.name == "write_file"
      assert tc.args == %{"path" => "foo.ex"}
    end

    test "requests and surfaces provider-reported OpenAI stream usage", %{port: port} do
      Process.register(self(), :stream_usage_test)

      on_exit(fn ->
        if Process.whereis(:stream_usage_test) == self(),
          do: Process.unregister(:stream_usage_test)
      end)

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/openai/usage",
        body: %{"model" => "gpt-4o", "messages" => []}
      ]

      assert {:ok, response} = StreamClient.stream(request_opts)
      assert response.text == "Measured"
      assert response.usage == %{prompt_tokens: 12, completion_tokens: 8, total_tokens: 20}
      assert response.raw["usage"]["total_tokens"] == 20

      assert_receive {:stream_request, request}
      assert request["stream_options"] == %{"include_usage" => true}
    end

    test "preserves total-only provider usage at the top level", %{port: port} do
      Process.register(self(), :stream_total_usage_test)

      on_exit(fn ->
        if Process.whereis(:stream_total_usage_test) == self(),
          do: Process.unregister(:stream_total_usage_test)
      end)

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/openai/usage-total-only",
        body: %{"model" => "compatible-model", "messages" => []}
      ]

      assert {:ok, response} = StreamClient.stream(request_opts)
      assert response.text == "Total only"

      assert response.usage == %{
               prompt_tokens: 0,
               completion_tokens: 0,
               total_tokens: 50
             }

      assert response.raw["usage"] == %{"total_tokens" => 50}

      assert_receive {:stream_request, request}
      assert request["stream_options"] == %{"include_usage" => true}
    end

    test "handles HTTP error status codes", %{port: port} do
      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/error/500",
        body: %{}
      ]

      assert {:error, %{status: 500}} = StreamClient.stream(request_opts)
    end

    test "bounds oversized success streams before callback accumulation", %{port: port} do
      {:ok, callback_count} = Agent.start_link(fn -> 0 end)

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/openai/oversized-success",
        body: %{}
      ]

      assert {:error, :response_too_large} =
               StreamClient.stream(request_opts, fn _chunk ->
                 Agent.update(callback_count, &(&1 + 1))
               end)

      assert Agent.get(callback_count, & &1) == 0
      Agent.stop(callback_count)
    end

    test "bounds error bodies and redacts exact authorization credentials", %{port: port} do
      secret = "adversarial-provider-secret"

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/error/oversized-secret",
        headers: [{"authorization", "Bearer #{secret}"}],
        body: %{}
      ]

      assert {:error, %{status: 500, body: body}} = StreamClient.stream(request_opts)
      assert byte_size(body) <= 64_000
      assert body == "Upstream error body exceeded 64000 bytes"
      refute body =~ secret
      refute body =~ "Bearer #{secret}"
    end

    test "preserves bounded small error detail while redacting credentials", %{port: port} do
      secret = "small-provider-secret"

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/error/small-secret",
        headers: [{"authorization", "Bearer #{secret}"}],
        body: %{}
      ]

      assert {:error, %{status: 500, body: "upstream echoed [REDACTED]"}} =
               StreamClient.stream(request_opts)
    end

    test "never returns a credential fragment crossing the error cutoff", %{port: port} do
      secret = "cutoff-provider-secret"

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/error/cutoff-secret",
        headers: [{"authorization", "Bearer #{secret}"}],
        body: %{}
      ]

      assert {:error, %{status: 500, body: "Upstream error body exceeded 64000 bytes"} = error} =
               StreamClient.stream(request_opts)

      rendered = inspect(error)
      refute rendered =~ secret
      refute rendered =~ String.slice(secret, 0, 5)
    end

    test "redacts credentials from callback exceptions", %{port: port} do
      secret = "callback-secret"

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/openai/stream",
        headers: [{"x-api-key", secret}],
        body: %{}
      ]

      assert {:error, %RuntimeError{message: "callback exposed [REDACTED]"} = error} =
               StreamClient.stream(request_opts, fn _chunk ->
                 raise "callback exposed #{secret}"
               end)

      rendered = inspect(error)
      assert rendered =~ "[REDACTED]"
      refute rendered =~ secret
    end

    test "redacts credentials from every callback exception field", %{port: port} do
      secret = "structured-callback-secret"

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/openai/stream",
        headers: [{"authorization", "Bearer #{secret}"}],
        body: %{}
      ]

      assert {:error,
              %SecretCallbackError{
                message: "callback failed",
                context: %{credential: "[REDACTED]"}
              } = error} =
               StreamClient.stream(request_opts, fn _chunk ->
                 raise SecretCallbackError,
                   message: "callback failed",
                   context: %{credential: secret}
               end)

      refute inspect(error) =~ secret
    end

    test "redacts credentials represented as printable charlists in callback errors", %{
      port: port
    } do
      secret = "charlist-callback-secret"

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/openai/stream",
        headers: [{"x-api-key", secret}],
        body: %{}
      ]

      assert {:error, %SecretCallbackError{context: %{credential: "[REDACTED]"}} = error} =
               StreamClient.stream(request_opts, fn _chunk ->
                 raise SecretCallbackError,
                   message: "callback failed",
                   context: %{credential: String.to_charlist(secret)}
               end)

      refute inspect(error) =~ secret
      refute inspect(error) =~ inspect(String.to_charlist(secret))
    end

    test "extracts credentials from charlist authorization headers when accepted", %{port: port} do
      secret = "charlist-secret"

      request_opts = [
        provider: "openai",
        url: "http://127.0.0.1:#{port}/error/small-secret",
        headers: [{"authorization", String.to_charlist("Bearer #{secret}")}],
        body: %{}
      ]

      case StreamClient.stream(request_opts) do
        {:error, %{status: 500, body: body}} ->
          assert body =~ "[REDACTED]"
          refute body =~ secret

        {:error, %{kind: :network}} ->
          # Current Req rejects non-binary header iodata before sending it. The
          # credential extractor still supports it if a future Req accepts it.
          :ok
      end
    end
  end
end
