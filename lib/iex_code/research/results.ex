defmodule IexCode.Research.Results do
  @moduledoc "Durable public IDs, immutable files, and chat attachments for deep research."

  import Ecto.Query, warn: false
  require Logger

  alias IexCode.Repo
  alias IexCode.Research.{HTMLReport, ResearchResult, ResultStore}
  alias IexCode.Runs.Run

  @max_attachment_bytes 512_000
  @max_attachment_context_bytes 90_000
  @max_public_id 9_223_372_036_854_775_807

  @doc "Subscribes the caller to durable research-result lifecycle notifications for a session."
  def subscribe_session(session_id) when is_binary(session_id) and session_id != "" do
    Phoenix.PubSub.subscribe(IexCode.PubSub, "research:session:#{session_id}")
  end

  def subscribe_session(_session_id), do: {:error, :invalid_session_id}

  @doc "Registers one monotonically increasing public research ID for a deep-research run."
  def register(run, level, metadata \\ %{})

  def register(%Run{kind: "deep_research"} = run, level, metadata)
      when level in ~w(low medium high ultra) and is_map(metadata) do
    changeset =
      ResearchResult.create_changeset(%ResearchResult{}, %{
        run_id: run.id,
        project_id: run.project_id,
        session_id: run.session_id,
        objective: run.objective,
        level: level,
        status: "queued",
        metadata: metadata
      })

    result =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current_run = Repo.get!(Run, run.id)
          assert_unleased_run!(current_run)

          case Repo.get_by(ResearchResult, run_id: run.id) do
            %ResearchResult{level: ^level} = existing ->
              existing

            %ResearchResult{} ->
              Repo.rollback(:research_result_identity_conflict)

            nil ->
              case Repo.insert(changeset) do
                {:ok, result} -> result
                {:error, error_changeset} -> Repo.rollback(error_changeset)
              end
          end
        end)
      end)

    unwrap_transaction(result)
  end

  def register(%Run{}, _level, _metadata), do: {:error, :not_a_deep_research_run}
  def register(_run, _level, _metadata), do: {:error, :invalid_research_registration}

  def get(id) when is_integer(id) and id > 0 and id <= @max_public_id,
    do: Repo.get(ResearchResult, id)

  def get(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 and parsed <= @max_public_id -> get(parsed)
      _other -> nil
    end
  end

  def get(_id), do: nil

  def get_by_run(%Run{id: id}), do: Repo.get_by(ResearchResult, run_id: id)
  def get_by_run(id) when is_binary(id), do: Repo.get_by(ResearchResult, run_id: id)
  def get_by_run(_run), do: nil

  def get_ready(id) do
    case get(id) do
      %ResearchResult{status: "ready"} = result -> result
      _result -> nil
    end
  end

  def get_ready_for_session(id, session_id) when is_binary(session_id) do
    case get_ready(id) do
      %ResearchResult{session_id: ^session_id} = result -> result
      _result -> nil
    end
  end

  def get_ready_for_session(_id, _session_id), do: nil

  def list_ready(opts \\ []) when is_list(opts) do
    ResearchResult
    |> where([result], result.status == "ready")
    |> maybe_where(:session_id, opts[:session_id])
    |> maybe_where(:project_id, opts[:project_id])
    |> order_by([result], desc: result.id)
    |> limit(^bounded_limit(opts[:limit], 100))
    |> Repo.all()
  end

  @doc false
  def list_unmaterialized_completed(opts \\ []) when is_list(opts) do
    opts
    |> list_unmaterialized_completed_page()
    |> Enum.map(& &1.run)
  end

  @doc false
  def list_unmaterialized_completed_page(opts \\ []) when is_list(opts) do
    after_id =
      if is_integer(opts[:after_id]) and opts[:after_id] >= 0, do: opts[:after_id], else: 0

    ResearchResult
    |> join(:inner, [result], run in Run, on: run.id == result.run_id)
    |> where(
      [result, run],
      result.id > ^after_id and result.status != "ready" and run.status == "completed" and
        run.kind == "deep_research" and run.execution_engine == "dag_v1"
    )
    |> order_by([result, _run], asc: result.id)
    |> limit(^bounded_limit(opts[:limit], 1_000))
    |> select([result, run], %{result_id: result.id, run: run})
    |> Repo.all()
  end

  def mark_running(result_or_id), do: transition(result_or_id, "running", %{})

  def mark_failed(result_or_id, code) when is_binary(code) and byte_size(code) in 1..160 do
    transition(result_or_id, "failed", %{
      completed_at: now(),
      metadata: %{"failure_code" => code}
    })
  end

  def mark_failed(_result_or_id, _code), do: {:error, :invalid_failure_code}

  def mark_cancelled(result_or_id) do
    transition(result_or_id, "cancelled", %{completed_at: now()})
  end

  @doc false
  def prepare_run(%Run{kind: "deep_research"} = run), do: do_prepare_run(run, nil)

  def prepare_run(%Run{}), do: {:ok, nil}
  def prepare_run(_run), do: {:error, :invalid_research_run}

  @doc false
  def prepare_run_worker(%Run{kind: "deep_research"} = run, authority) when is_list(authority) do
    with :ok <- validate_worker_authority(authority) do
      do_prepare_run(run, authority)
    end
  end

  def prepare_run_worker(%Run{}, _authority), do: {:ok, nil}

  def prepare_run_worker(_run, _authority), do: {:error, :invalid_worker_authority}

  defp do_prepare_run(%Run{} = run, authority) do
    transaction =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current_run = Repo.get!(Run, run.id)

          if authority,
            do: assert_worker_authority!(current_run, authority),
            else: assert_unleased_run!(current_run)

          level = metadata_level(current_run.metadata)

          result =
            case Repo.get_by(ResearchResult, run_id: current_run.id) do
              %ResearchResult{level: ^level} = existing ->
                existing

              %ResearchResult{} ->
                Repo.rollback(:research_result_identity_conflict)

              nil ->
                %ResearchResult{}
                |> ResearchResult.create_changeset(%{
                  run_id: current_run.id,
                  project_id: current_run.project_id,
                  session_id: current_run.session_id,
                  objective: current_run.objective,
                  level: level,
                  status: "queued",
                  metadata: %{}
                })
                |> Repo.insert()
                |> case do
                  {:ok, created} -> created
                  {:error, changeset} -> Repo.rollback(changeset)
                end
            end

          case result.status do
            status when status in ["queued", "running"] ->
              result
              |> ResearchResult.transition_changeset(%{
                status: "running",
                metadata: result.metadata || %{}
              })
              |> Repo.update()
              |> case do
                {:ok, running} -> running
                {:error, changeset} -> Repo.rollback(changeset)
              end

            status ->
              Repo.rollback({:research_result_terminal, status})
          end
        end)
      end)

    unwrap_transaction(transaction)
  end

  @doc "Commits `result.md` and a self-contained HTML report, then marks the ID ready."
  def commit(result_or_id, markdown, opts \\ [])

  def commit(result_or_id, markdown, opts) when is_binary(markdown) and is_list(opts) do
    do_commit(result_or_id, markdown, opts, nil)
  end

  def commit(_result_or_id, _markdown, _opts), do: {:error, :invalid_research_commit}

  @doc false
  def commit_worker(result_or_id, markdown, opts, authority)
      when is_binary(markdown) and is_list(opts) and is_list(authority) do
    with :ok <- validate_worker_authority(authority),
         %ResearchResult{} = result <- resolve(result_or_id),
         {:ok, _run} <- IexCode.Runs.assert_run_worker(result.run_id, authority) do
      do_commit(result, markdown, opts, authority)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def commit_worker(_result_or_id, _markdown, _opts, _authority),
    do: {:error, :invalid_research_commit}

  defp do_commit(result_or_id, markdown, opts, authority) do
    with %ResearchResult{} = result <- resolve(result_or_id),
         :ok <- committable?(result),
         {:ok, commit_metadata} <- validate_commit_metadata(opts[:metadata]),
         {:ok, html} <- render_html(result, markdown, opts),
         root <- storage_root(opts),
         {:ok, markdown_object} <- ResultStore.put(root, markdown),
         {:ok, html_object} <- ResultStore.put(root, html),
         :ok <- before_ready(opts),
         result_path <- Path.join(Integer.to_string(result.id), "result.md"),
         html_path <- Path.join(Integer.to_string(result.id), "report.html"),
         {:ok, ready} <-
           persist_ready(
             result,
             result_path,
             html_path,
             markdown_object,
             html_object,
             Keyword.put(opts, :metadata, commit_metadata),
             authority
           ) do
      publication =
        materialize_accepted_paths(
          ready,
          root,
          [{markdown_object, result_path}, {html_object, html_path}]
        )

      case publication do
        :complete ->
          broadcast_lifecycle(ready, :ready, %{publication: :complete})

        {:repairable_failure, failures} ->
          broadcast_lifecycle(ready, :materialization_failed, %{
            publication: :repairable_failure,
            failures: failures
          })
      end

      {:ok, ready}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # Content-addressed objects are safe to leave behind if authority is lost.
  # Fixed public result paths are not: they are immutable and a stale worker
  # could otherwise occupy them before the fenced ready transition rejects it.
  # Keep this callback private and test-only in practice; production callers do
  # not supply it.
  defp before_ready(opts) do
    case opts[:before_ready] do
      callback when is_function(callback, 0) -> callback.()
      _callback -> :ok
    end
  end

  @doc false
  def mark_failed_worker(result_or_id, code, authority)
      when is_binary(code) and byte_size(code) in 1..160 and is_list(authority),
      do:
        transition_worker(
          result_or_id,
          "failed",
          %{completed_at: now(), metadata: %{"failure_code" => code}},
          authority
        )

  def mark_failed_worker(_result_or_id, _code, _authority),
    do: {:error, :invalid_failure_code}

  @doc false
  def mark_cancelled_worker(result_or_id, authority) when is_list(authority),
    do: transition_worker(result_or_id, "cancelled", %{completed_at: now()}, authority)

  def mark_cancelled_worker(_result_or_id, _authority),
    do: {:error, :invalid_worker_authority}

  def read_markdown(result, opts \\ [])

  def read_markdown(%ResearchResult{status: "ready"} = result, opts) do
    read_ready_file(storage_root(opts), result.result_path, result.markdown_sha256)
  end

  def read_markdown(_result, _opts), do: {:error, :research_result_not_ready}

  def read_html(result, opts \\ [])

  def read_html(%ResearchResult{status: "ready"} = result, opts) do
    read_ready_file(storage_root(opts), result.html_path, result.html_sha256)
  end

  def read_html(_result, _opts), do: {:error, :research_result_not_ready}

  @doc "Returns a bounded, integrity-checked context object for a session-scoped slash attachment."
  def context_attachment(id, session_id, opts \\ [])

  def context_attachment(id, session_id, opts) when is_binary(session_id) do
    maximum = bounded_attachment(opts[:max_bytes])

    with %ResearchResult{} = result <- get_ready_for_session(id, session_id),
         {:ok, markdown} <- read_markdown(result, opts),
         true <-
           byte_size(markdown) <= maximum or {:error, {:research_context_too_large, maximum}} do
      {:ok,
       %{
         "type" => "deep_research",
         "id" => result.id,
         "objective" => result.objective,
         "level" => result.level,
         "sha256" => result.markdown_sha256,
         "content" => markdown
       }}
    else
      nil -> {:error, :research_result_not_found}
      false -> {:error, :invalid_research_context}
      {:error, _reason} = error -> error
    end
  end

  def context_attachment(_id, _session_id, _opts), do: {:error, :invalid_research_context}

  @doc "Resolves an ordered, session-bound set of verified attachment references and content."
  def context_attachments(ids, session_id, opts \\ [])

  def context_attachments(ids, session_id, opts)
      when is_list(ids) and is_binary(session_id) and is_list(opts) do
    maximum = bounded_context_bytes(opts[:max_bytes])

    with true <- length(ids) <= 12 or {:error, :too_many_research_attachments},
         true <-
           Enum.all?(ids, &(is_integer(&1) and &1 > 0)) or
             {:error, :invalid_research_attachment_id},
         {:ok, attachments} <- resolve_context_attachments(Enum.uniq(ids), session_id, opts),
         {:ok, encoded} <- IexCode.Runs.DagPayload.canonical_json(attachments),
         true <-
           byte_size(encoded) <= maximum or
             {:error, {:research_context_too_large, maximum}} do
      {:ok, attachments}
    else
      false -> {:error, :invalid_research_context}
      {:error, _reason} = error -> error
    end
  end

  def context_attachments(_ids, _session_id, _opts),
    do: {:error, :invalid_research_context}

  @doc "Returns immutable references for session-bound, checksum-verified attachments."
  def attachment_refs(ids, session_id, opts \\ []) do
    with {:ok, attachments} <- context_attachments(ids, session_id, opts) do
      {:ok, Enum.map(attachments, &Map.take(&1, ~w(id sha256)))}
    end
  end

  @doc false
  def resolve_attachment_refs(refs, session_id, opts \\ [])

  def resolve_attachment_refs(refs, session_id, opts)
      when is_list(refs) and is_binary(session_id) and is_list(opts) do
    with true <- valid_attachment_refs?(refs) or {:error, :invalid_research_attachment_refs},
         {:ok, attachments} <-
           context_attachments(Enum.map(refs, & &1["id"]), session_id, opts),
         true <-
           Enum.zip(refs, attachments)
           |> Enum.all?(fn {reference, attachment} ->
             reference["id"] == attachment["id"] and
               reference["sha256"] == attachment["sha256"]
           end) or {:error, :research_attachment_integrity_error} do
      {:ok, attachments}
    else
      false -> {:error, :invalid_research_context}
      {:error, _reason} = error -> error
    end
  end

  def resolve_attachment_refs(_refs, _session_id, _opts),
    do: {:error, :invalid_research_attachment_refs}

  def storage_root(opts \\ []) do
    Keyword.get_lazy(opts, :root, fn ->
      app_dir =
        Application.get_env(:iex_code, :app_dir) ||
          database_directory(IexCode.Repo.config()[:database])

      Path.join(app_dir, "research")
    end)
  end

  defp persist_ready(
         result,
         result_path,
         html_path,
         markdown_object,
         html_object,
         opts,
         authority
       ) do
    metadata =
      (opts[:metadata] || %{})
      |> Map.put("markdown_object", object_ref(markdown_object))
      |> Map.put("html_object", object_ref(html_object))

    transaction =
      Repo.retry_on_busy(fn ->
        Repo.transaction(fn ->
          current = Repo.get!(ResearchResult, result.id)
          run = Repo.get!(Run, current.run_id)

          if authority,
            do: assert_worker_authority!(run, authority),
            else: assert_unleased_run!(run)

          case committable?(current) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          if current.status == "ready" do
            if ready_identity?(current, markdown_object.digest, html_object.digest) do
              current
            else
              Repo.rollback(:research_object_collision)
            end
          else
            changeset =
              ResearchResult.transition_changeset(current, %{
                status: "ready",
                result_path: result_path,
                html_path: html_path,
                markdown_sha256: markdown_object.digest,
                html_sha256: html_object.digest,
                source_count: bounded_source_count(opts[:source_count]),
                metadata: metadata,
                completed_at: now()
              })

            case Repo.update(changeset) do
              {:ok, ready} -> ready
              {:error, error_changeset} -> Repo.rollback(error_changeset)
            end
          end
        end)
      end)

    unwrap_transaction(transaction)
  end

  # The ready transaction is the authority boundary: after it accepts the
  # digests, publishing those exact content-addressed objects is safe even if
  # the worker subsequently loses its lease. A crash between that transaction
  # and materialization is repaired lazily from the accepted digest.
  defp read_ready_file(root, path, digest) do
    case ResultStore.read(root, path, digest) do
      {:ok, _body} = ok ->
        ok

      {:error, _reason} = original_error ->
        case ResultStore.materialize_digest(root, digest, path) do
          {:ok, _path} -> ResultStore.read(root, path, digest)
          {:error, _reason} -> original_error
        end
    end
  end

  # The ready transaction durably accepts the content-addressed objects. Fixed
  # paths are a derived cache and must not turn that committed success into a
  # parent-run failure if publication is interrupted. Reads repair missing
  # paths. An existing mismatched destination remains an integrity error; it is
  # never silently replaced or served around.
  defp materialize_accepted_paths(ready, root, objects_and_paths) do
    failures =
      Enum.reduce(objects_and_paths, [], fn {object, path}, failures ->
        case ResultStore.materialize(root, object, path) do
          {:ok, _path} ->
            failures

          {:error, reason} ->
            Logger.warning(
              "Research result #{ready.id} accepted object #{object.digest} but path publication failed: #{inspect(reason)}"
            )

            [%{path: path, reason: stable_publication_reason(reason)} | failures]
        end
      end)

    case Enum.reverse(failures) do
      [] ->
        :complete

      failures ->
        {:repairable_failure, failures}
    end
  end

  defp stable_publication_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp stable_publication_reason({reason, _detail}) when is_atom(reason),
    do: Atom.to_string(reason)

  defp stable_publication_reason(_reason), do: "publication_failed"

  defp broadcast_lifecycle(%ResearchResult{} = result, lifecycle, details)
       when is_atom(lifecycle) and is_map(details) do
    payload = %{result: result, lifecycle: lifecycle, details: details}

    Phoenix.PubSub.broadcast(
      IexCode.PubSub,
      "research:session:#{result.session_id}",
      {:research_result_updated, payload}
    )

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp transition(result_or_id, status, attrs) do
    with %ResearchResult{} = result <- resolve(result_or_id) do
      transaction =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(ResearchResult, result.id)
            run = Repo.get!(Run, current.run_id)
            assert_unleased_run!(run)

            case transition_allowed?(current.status, status) do
              :ok ->
                current
                |> ResearchResult.transition_changeset(
                  attrs
                  |> Map.put(:status, status)
                  |> Map.put_new(:metadata, current.metadata || %{})
                )
                |> Repo.update()
                |> case do
                  {:ok, updated} -> updated
                  {:error, changeset} -> Repo.rollback(changeset)
                end

              {:error, reason} ->
                Repo.rollback(reason)
            end
          end)
        end)

      transaction
      |> unwrap_transaction()
      |> broadcast_transition_result()
    else
      nil -> {:error, :not_found}
    end
  end

  defp transition_worker(result_or_id, status, attrs, authority) do
    with :ok <- validate_worker_authority(authority),
         %ResearchResult{} = result <- resolve(result_or_id) do
      transaction =
        Repo.retry_on_busy(fn ->
          Repo.transaction(fn ->
            current = Repo.get!(ResearchResult, result.id)
            run = Repo.get!(Run, current.run_id)
            assert_worker_authority!(run, authority)

            case transition_allowed?(current.status, status) do
              :ok ->
                current
                |> ResearchResult.transition_changeset(
                  attrs
                  |> Map.put(:status, status)
                  |> Map.put_new(:metadata, current.metadata || %{})
                )
                |> Repo.update()
                |> case do
                  {:ok, updated} -> updated
                  {:error, changeset} -> Repo.rollback(changeset)
                end

              {:error, reason} ->
                Repo.rollback(reason)
            end
          end)
        end)

      transaction
      |> unwrap_transaction()
      |> broadcast_transition_result()
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp transition_allowed?(status, status), do: :ok
  defp transition_allowed?("queued", status) when status in ~w(running failed cancelled), do: :ok
  defp transition_allowed?("running", status) when status in ~w(ready failed cancelled), do: :ok

  defp transition_allowed?(from, to),
    do: {:error, {:invalid_research_result_transition, from, to}}

  defp broadcast_transition_result({:ok, %ResearchResult{} = result} = success) do
    broadcast_lifecycle(result, lifecycle_atom(result.status), %{})
    success
  end

  defp broadcast_transition_result(other), do: other

  defp lifecycle_atom("queued"), do: :queued
  defp lifecycle_atom("running"), do: :running
  defp lifecycle_atom("ready"), do: :ready
  defp lifecycle_atom("failed"), do: :failed
  defp lifecycle_atom("cancelled"), do: :cancelled

  defp validate_worker_authority(authority) do
    owner = authority[:lease_owner]
    attempt = authority[:run_attempt]
    generation = authority[:lease_generation]

    if is_binary(owner) and owner != "" and is_integer(attempt) and attempt >= 1 and
         is_integer(generation) and generation >= 1 do
      :ok
    else
      {:error, :invalid_worker_authority}
    end
  end

  defp assert_worker_authority!(run, authority) do
    valid? =
      run.status in ["running", "paused"] and run.lease_owner == authority[:lease_owner] and
        run.attempt == authority[:run_attempt] and
        run.lease_generation == authority[:lease_generation] and
        is_struct(run.lease_expires_at, DateTime) and
        DateTime.compare(run.lease_expires_at, now()) == :gt

    if valid?, do: :ok, else: Repo.rollback(:lease_not_owned)
  end

  defp assert_unleased_run!(%Run{lease_owner: nil}), do: :ok
  defp assert_unleased_run!(%Run{}), do: Repo.rollback(:worker_authority_required)

  defp committable?(%ResearchResult{status: status}) when status in ["running", "ready"], do: :ok

  defp committable?(%ResearchResult{status: status}),
    do: {:error, {:research_result_not_active, status}}

  defp render_html(result, markdown, opts) do
    HTMLReport.render(markdown,
      title: result.objective,
      subtitle: "#{String.capitalize(result.level)} deep research · result ##{result.id}",
      generated_at: result.inserted_at,
      source_count: bounded_source_count(opts[:source_count])
    )
  end

  defp validate_commit_metadata(nil), do: {:ok, %{}}

  defp validate_commit_metadata(metadata) when is_map(metadata) do
    case IexCode.Runs.DagPayload.validate(metadata, max_bytes: 64_000) do
      {:ok, validated} when is_map(validated) -> {:ok, validated}
      {:ok, _validated} -> {:error, :invalid_research_metadata}
      {:error, reason} -> {:error, {:invalid_research_metadata, reason}}
    end
  end

  defp validate_commit_metadata(_metadata), do: {:error, :invalid_research_metadata}

  defp ready_identity?(result, markdown_digest, html_digest),
    do: result.markdown_sha256 == markdown_digest and result.html_sha256 == html_digest

  defp object_ref(object) do
    %{"sha256" => object.digest, "byte_size" => object.byte_size}
  end

  defp resolve(%ResearchResult{id: id}), do: Repo.get(ResearchResult, id)
  defp resolve(id), do: get(id)

  defp maybe_where(query, _field, nil), do: query

  defp maybe_where(query, :session_id, value),
    do: where(query, [result], result.session_id == ^value)

  defp maybe_where(query, :project_id, value),
    do: where(query, [result], result.project_id == ^value)

  defp bounded_limit(value, _default) when is_integer(value), do: value |> max(1) |> min(500)
  defp bounded_limit(_value, default), do: default

  defp bounded_attachment(value) when is_integer(value),
    do: value |> max(1) |> min(@max_attachment_bytes)

  defp bounded_attachment(_value), do: @max_attachment_bytes

  defp bounded_context_bytes(value) when is_integer(value),
    do: value |> max(1) |> min(@max_attachment_context_bytes)

  defp bounded_context_bytes(_value), do: @max_attachment_context_bytes

  defp resolve_context_attachments(ids, session_id, opts) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, attachments} ->
      case context_attachment(id, session_id, opts) do
        {:ok, attachment} -> {:cont, {:ok, attachments ++ [attachment]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_attachment_refs?(refs) do
    ids = Enum.map(refs, fn reference -> if is_map(reference), do: reference["id"] end)

    length(refs) <= 12 and length(ids) == MapSet.size(MapSet.new(ids)) and
      Enum.all?(refs, fn
        %{"id" => id, "sha256" => digest} = reference
        when map_size(reference) == 2 and is_integer(id) and id > 0 ->
          is_binary(digest) and Regex.match?(~r/^[0-9a-f]{64}$/, digest)

        _reference ->
          false
      end)
  end

  defp bounded_source_count(value) when is_integer(value), do: value |> max(0) |> min(100_000)
  defp bounded_source_count(_value), do: 0

  defp database_directory(database) when is_binary(database) and database not in ["", ":memory:"],
    do: Path.dirname(database)

  defp database_directory(_database), do: File.cwd!()

  defp metadata_level(metadata) when is_map(metadata) do
    research = Map.get(metadata, "research", Map.get(metadata, :research, %{}))

    value =
      if is_map(research) do
        Map.get(research, "level", Map.get(research, :level)) ||
          Map.get(research, "depth", Map.get(research, :depth))
      end

    case value do
      level when level in ~w(low medium high ultra) -> level
      depth when depth in ["quick", :quick] -> "low"
      depth when depth in ["deep", :deep] -> "high"
      _value -> "medium"
    end
  end

  defp metadata_level(_metadata), do: "medium"

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
