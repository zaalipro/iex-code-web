defmodule IexCode.Sessions do
  @moduledoc """
  Context for managing sessions, conversation messages, and real-time swarm operations.
  """
  import Ecto.Query, warn: false
  require Logger
  alias IexCode.Repo
  alias IexCode.Runs.Run
  alias IexCode.Settings
  alias IexCode.Sessions.{Session, Message, Operation}

  def list_sessions_for_project(project_id) do
    Session
    |> where([s], s.project_id == ^project_id)
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
  end

  def get_session!(id) do
    Session
    |> Repo.get!(id)
    |> Repo.preload([:project])
  end

  def get_session(id) do
    case Repo.get(Session, id) do
      nil -> nil
      session -> Repo.preload(session, [:project])
    end
  end

  def create_session(attrs \\ %{})

  def create_session(attrs) when is_map(attrs) do
    attrs = seed_session_defaults(attrs, Settings.get_settings())

    Repo.retry_on_busy(fn ->
      %Session{}
      |> Session.changeset(attrs)
      |> Repo.insert()
    end)
  end

  def create_session(_attrs), do: {:error, :invalid_session_attributes}

  def update_session(%Session{} = session, attrs) do
    Repo.retry_on_busy(fn ->
      session
      |> Session.changeset(attrs)
      |> Repo.update()
    end)
  end

  def delete_session(%Session{} = session) do
    Repo.retry_on_busy(fn ->
      Repo.delete(session)
    end)
  end

  def list_messages(session_id), do: list_messages(session_id, [])

  @doc """
  Lists messages in chronological order.

  Passing `:limit` keeps interactive consumers from retaining an entire long-running
  conversation. `:before` accepts the first message from the previous page and
  returns the immediately preceding page. The unbounded arity is retained for
  engine callers that intentionally need the complete durable transcript.
  """
  def list_messages(session_id, opts) when is_list(opts) do
    limit = normalize_page_limit(Keyword.get(opts, :limit))
    content_limit = normalize_content_limit(Keyword.get(opts, :content_limit))
    before = Keyword.get(opts, :before)
    after_cursor = Keyword.get(opts, :after)

    query =
      Message
      |> where([m], m.session_id == ^session_id)
      |> before_message(before)
      |> after_message(after_cursor)
      |> limit_message_content(content_limit)

    cond do
      limit && after_cursor ->
        query
        |> order_by([m], asc: m.inserted_at, asc: m.id)
        |> limit(^limit)
        |> Repo.all()

      limit ->
        query
        |> order_by([m], desc: m.inserted_at, desc: m.id)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.reverse()

      true ->
        query
        |> order_by([m], asc: m.inserted_at, asc: m.id)
        |> Repo.all()
    end
  end

  defp before_message(query, %{inserted_at: inserted_at, id: id})
       when not is_nil(inserted_at) and is_binary(id) do
    where(
      query,
      [m],
      m.inserted_at < ^inserted_at or (m.inserted_at == ^inserted_at and m.id < ^id)
    )
  end

  defp before_message(query, _before), do: query

  defp after_message(query, %{inserted_at: inserted_at, id: id})
       when not is_nil(inserted_at) and is_binary(id) do
    where(
      query,
      [m],
      m.inserted_at > ^inserted_at or (m.inserted_at == ^inserted_at and m.id > ^id)
    )
  end

  defp after_message(query, _after), do: query

  defp normalize_page_limit(nil), do: nil
  defp normalize_page_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(1_000)
  defp normalize_page_limit(_invalid), do: nil
  defp normalize_content_limit(nil), do: nil

  defp normalize_content_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(1_000_000)

  defp normalize_content_limit(_invalid), do: nil

  defp limit_message_content(query, nil), do: query

  defp limit_message_content(query, limit) do
    select_merge(query, [m], %{content: fragment("substr(?, 1, ?)", m.content, ^limit)})
  end

  def get_message_by_idempotency_key(key) when is_binary(key) and key != "",
    do: Repo.get_by(Message, idempotency_key: key)

  def get_message_by_idempotency_key(_key), do: nil

  def get_message(session_id, id) when is_binary(session_id) and is_binary(id),
    do: Repo.get_by(Message, id: id, session_id: session_id)

  def get_message(_session_id, _id), do: nil

  @doc false
  def latest_goal_checkpoint(session_id) do
    Message
    |> where([m], m.session_id == ^session_id and m.agent_name == "User (Goal)")
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(1)
    |> Repo.one()
  end

  def create_message(attrs \\ %{}) do
    Repo.retry_on_busy(fn ->
      %Message{}
      |> Message.changeset(sanitize_attrs(attrs))
      |> Repo.insert()
    end)
  end

  @doc """
  Creates one message for a stable local identity, or returns the exact existing
  message when an identical request is retried. The database unique index is the
  concurrency boundary; conflicting reuse of a key fails closed.
  """
  def create_message_once(attrs, idempotency_key)

  def create_message_once(attrs, idempotency_key)
      when is_map(attrs) and is_binary(idempotency_key) do
    attrs =
      attrs
      |> sanitize_attrs()
      |> Map.put(:idempotency_key, idempotency_key)

    changeset = Message.changeset(%Message{}, attrs)

    if changeset.valid? do
      Repo.retry_on_busy(fn -> insert_message_once(changeset) end)
    else
      {:error, changeset}
    end
  end

  def create_message_once(_attrs, _idempotency_key),
    do: {:error, :invalid_message_idempotency_request}

  @doc "Ensures the canonical durable user turn for a run exists exactly once."
  def ensure_run_user_message(%Run{} = run) do
    key = "run-user:#{run.id}"
    intent = run_intent(run.metadata)

    attrs = %{
      session_id: run.session_id,
      role: "user",
      agent_name: durable_user_agent(intent),
      content: durable_user_content(run, intent),
      metadata: %{
        "run_id" => run.id,
        "request_key" => run.request_key,
        "intent" => intent,
        "source" => run_source(run.metadata)
      }
    }

    case Repo.retry_on_busy(fn -> Repo.get_by(Message, idempotency_key: key) end) do
      %Message{} = existing ->
        if durable_user_message_for_run?(existing, run),
          do: {:ok, existing, :existing},
          else: {:error, :message_idempotency_conflict}

      nil ->
        create_message_once(attrs, key)
    end
  end

  def ensure_run_user_message(_run), do: {:error, :invalid_durable_run_message}

  defp insert_message_once(changeset) do
    case Repo.insert(changeset) do
      {:ok, message} ->
        {:ok, message, :created}

      {:error, failed_changeset} ->
        if idempotency_conflict?(failed_changeset) do
          key = Ecto.Changeset.get_field(changeset, :idempotency_key)

          case Repo.get_by(Message, idempotency_key: key) do
            %Message{} = existing ->
              if same_message_request?(existing, Ecto.Changeset.apply_changes(changeset)),
                do: {:ok, existing, :existing},
                else: {:error, :message_idempotency_conflict}

            nil ->
              {:error, failed_changeset}
          end
        else
          {:error, failed_changeset}
        end
    end
  end

  defp idempotency_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:idempotency_key, {_message, metadata}} ->
        metadata[:constraint] == :unique and
          metadata[:constraint_name] == "messages_idempotency_key_index"

      _error ->
        false
    end)
  end

  defp same_message_request?(existing, requested) do
    Enum.all?(
      ~w(session_id role agent_name content tool_calls metadata input_tokens output_tokens cost_cents)a,
      &(Map.get(existing, &1) == Map.get(requested, &1))
    )
  end

  defp durable_user_message_for_run?(message, run) do
    metadata = message.metadata || %{}
    intent = run_intent(run.metadata)
    expected_content = durable_user_content(run, intent)
    allowed_agents = [durable_user_agent(intent), "User"]

    canonical_shape? =
      (message.agent_name in allowed_agents and message.content == expected_content) or
        (message.agent_name == "User (Durable Run)" and message.content == run.objective)

    message.session_id == run.session_id and message.role == "user" and
      canonical_shape? and
      (Map.get(metadata, "run_id") || Map.get(metadata, :run_id)) == run.id
  end

  defp run_intent(metadata) when is_map(metadata) do
    snapshot = Map.get(metadata, "intent") || Map.get(metadata, :intent) || %{}
    Map.get(snapshot, "kind") || Map.get(snapshot, :kind) || legacy_run_intent(metadata)
  end

  defp run_intent(_metadata), do: "run"

  defp legacy_run_intent(metadata) do
    case Map.get(metadata, "source") || Map.get(metadata, :source) do
      "autonomous_goal" -> "goal"
      _source -> "run"
    end
  end

  defp run_source(metadata) when is_map(metadata) do
    snapshot = Map.get(metadata, "intent") || Map.get(metadata, :intent) || %{}

    Map.get(snapshot, "source") || Map.get(snapshot, :source) || Map.get(metadata, "source") ||
      Map.get(metadata, :source) || "durable_run"
  end

  defp run_source(_metadata), do: "durable_run"

  defp durable_user_agent("goal"), do: "User (Goal)"
  defp durable_user_agent("research"), do: "User (Research)"
  defp durable_user_agent(_intent), do: "User (Durable Run)"

  defp durable_user_content(run, "goal"), do: "Goal: #{run.objective}"
  defp durable_user_content(run, _intent), do: run.objective

  def list_operations(session_id), do: list_operations(session_id, [])

  def list_operations(session_id, opts) when is_list(opts) do
    limit = normalize_page_limit(Keyword.get(opts, :limit))

    query = where(Operation, [o], o.session_id == ^session_id)

    if limit do
      query
      |> order_by([o], desc: o.inserted_at, desc: o.id)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.reverse()
    else
      query
      |> order_by([o], asc: o.inserted_at)
      |> Repo.all()
    end
  end

  def get_operation!(id), do: Repo.get!(Operation, id)

  def get_operation(id), do: Repo.get(Operation, id)

  def create_operation(attrs \\ %{}) do
    Repo.retry_on_busy(fn ->
      %Operation{}
      |> Operation.changeset(project_operation_attrs(attrs))
      |> Repo.insert()
    end)
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Sessions.create_operation failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  def update_operation(op_or_id, attrs) do
    op_id =
      case op_or_id do
        %Operation{id: id} -> id
        id when is_binary(id) -> id
        _ -> nil
      end

    case op_id && Repo.get(Operation, op_id) do
      nil ->
        {:error, :not_found}

      %Operation{} = op ->
        op
        |> Operation.changeset(project_operation_attrs(attrs))
        |> Repo.update()
    end
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Sessions.update_operation failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  def sanitize_utf8(nil), do: nil

  def sanitize_utf8(term) when is_binary(term) do
    if String.valid?(term) do
      term
    else
      case :unicode.characters_to_binary(term, :utf8, :utf8) do
        {:error, valid, _rest} -> valid <> " [binary truncated]"
        {:incomplete, valid, _rest} -> valid
        binary when is_binary(binary) -> binary
      end
    end
  end

  def sanitize_utf8(%DateTime{} = dt), do: dt
  def sanitize_utf8(%Date{} = d), do: d
  def sanitize_utf8(%Time{} = t), do: t
  def sanitize_utf8(%NaiveDateTime{} = ndt), do: ndt
  def sanitize_utf8(%{__struct__: _} = struct), do: struct

  def sanitize_utf8(term) when is_map(term) do
    Map.new(term, fn {k, v} -> {sanitize_utf8(k), sanitize_utf8(v)} end)
  end

  def sanitize_utf8(term) when is_list(term) do
    Enum.map(term, &sanitize_utf8/1)
  end

  def sanitize_utf8(term), do: term

  defp sanitize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {k, sanitize_utf8(v)} end)
  end

  defp sanitize_attrs(attrs), do: attrs

  defp project_operation_attrs(attrs) when is_map(attrs) do
    attrs
    |> sanitize_attrs()
    |> project_operation_field(:params, &IexCode.Engine.OperationProjection.params/1)
    |> project_operation_field(:result, &IexCode.Engine.OperationProjection.text/1)
    |> project_operation_field(:error_message, &IexCode.Engine.OperationProjection.text/1)
  end

  defp project_operation_attrs(attrs), do: attrs

  defp project_operation_field(attrs, key, projector) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) and not is_nil(Map.get(attrs, key)) ->
        Map.update!(attrs, key, projector)

      Map.has_key?(attrs, string_key) and not is_nil(Map.get(attrs, string_key)) ->
        Map.update!(attrs, string_key, projector)

      true ->
        attrs
    end
  end

  def clear_session_operations(session_id) do
    Operation
    |> where([o], o.session_id == ^session_id)
    |> Repo.delete_all()
  end

  @doc """
  Queries real LLM usage history aggregated from messages and sessions.

  This compatibility wrapper returns an empty list when telemetry storage is
  unavailable. New UI surfaces that need to distinguish a real empty history
  from a storage failure must use `fetch_usage_history/2`.
  """
  def list_usage_history(limit \\ 10, opts \\ [])

  def list_usage_history(limit, opts) do
    case fetch_usage_history(limit, opts) do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  @doc """
  Fetches observed usage history with an explicit success/error result.

  Unlike `list_usage_history/2`, database failures are never represented as an
  honest empty history.
  """
  def fetch_usage_history(limit \\ 10, opts \\ [])

  def fetch_usage_history(limit, opts)
      when is_integer(limit) and limit > 0 and is_list(opts) do
    query =
      from(m in Message,
        join: s in assoc(m, :session),
        where: m.input_tokens > 0 or m.output_tokens > 0 or m.cost_cents > 0,
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        select: %{
          id: m.id,
          date: m.inserted_at,
          model: s.model_name,
          provider: s.model_provider,
          tokens: m.input_tokens + m.output_tokens,
          input_tokens: m.input_tokens,
          output_tokens: m.output_tokens,
          cost_cents: m.cost_cents
        }
      )

    query = maybe_scope_usage_query(query, opts[:session_id])
    {:ok, Repo.retry_on_busy(fn -> Repo.all(query) end)}
  rescue
    error -> {:error, {:db_error, Exception.message(error)}}
  end

  def fetch_usage_history(_limit, _opts), do: {:error, :invalid_arguments}

  @doc """
  Returns provider-reported token and cost totals without synthetic session rows.

  This compatibility wrapper returns zero totals on a storage failure. New UI
  surfaces should use `fetch_usage_totals/1` so that failure remains visible.
  """
  def usage_totals(opts \\ [])

  def usage_totals(opts) do
    case fetch_usage_totals(opts) do
      {:ok, totals} -> totals
      {:error, _reason} -> Map.put(zero_usage_totals(), :tokens, 0)
    end
  end

  @doc "Fetches observed usage totals with an explicit success/error result."
  def fetch_usage_totals(opts \\ [])

  def fetch_usage_totals(opts) when is_list(opts) do
    query =
      from(m in Message,
        where: m.input_tokens > 0 or m.output_tokens > 0 or m.cost_cents > 0,
        select: %{
          input_tokens: coalesce(sum(m.input_tokens), 0),
          output_tokens: coalesce(sum(m.output_tokens), 0),
          cost_cents: coalesce(sum(m.cost_cents), 0),
          requests: count(m.id)
        }
      )

    query = maybe_scope_usage_query(query, opts[:session_id])
    totals = Repo.retry_on_busy(fn -> Repo.one(query) end) || zero_usage_totals()
    {:ok, Map.put(totals, :tokens, totals.input_tokens + totals.output_tokens)}
  rescue
    error -> {:error, {:db_error, Exception.message(error)}}
  end

  def fetch_usage_totals(_opts), do: {:error, :invalid_arguments}

  def session_usage_totals(session_id) when is_binary(session_id),
    do: usage_totals(session_id: session_id)

  def session_usage_totals(_session_id), do: Map.put(zero_usage_totals(), :tokens, 0)

  defp maybe_scope_usage_query(query, session_id) when is_binary(session_id) and session_id != "",
    do: where(query, [m], m.session_id == ^session_id)

  defp maybe_scope_usage_query(query, _session_id), do: query

  defp zero_usage_totals,
    do: %{input_tokens: 0, output_tokens: 0, cost_cents: 0, requests: 0}

  defp seed_session_defaults(attrs, settings) do
    attrs
    |> put_default_attr(:model_provider, settings.default_model_provider)
    |> put_default_attr(:model_name, settings.default_model)
    |> put_default_attr(:temperature, settings.temperature)
    |> put_default_attr(:swarm_mode, settings.default_run_mode == "swarm")
  end

  defp put_default_attr(attrs, field, value) do
    string_field = Atom.to_string(field)

    if Map.has_key?(attrs, field) or Map.has_key?(attrs, string_field),
      do: attrs,
      else: Map.put(attrs, field, value)
  end
end
