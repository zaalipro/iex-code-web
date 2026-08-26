defmodule IexCode.Research.DagContracts do
  @moduledoc """
  Versioned, bounded envelopes exchanged by finite research DAG handlers.

  Envelopes are JSON-only and secret-rejecting. Their artifact descriptor is a
  proposal: the DAG scheduler must commit the body and immutable artifact row
  atomically before the descriptor becomes durable artifact truth.
  """

  alias IexCode.Research.LevelPolicy
  alias IexCode.Runs.DagPayload

  @version 1
  @max_output_bytes 240_000

  @type envelope :: %{
          required(String.t()) => term()
        }

  @spec wrap(String.t(), String.t(), map(), map()) :: {:ok, envelope()} | {:error, term()}
  def wrap(contract, artifact_kind, data, usage \\ %{})

  def wrap(contract, artifact_kind, data, usage)
      when is_binary(contract) and is_binary(artifact_kind) and is_map(data) and is_map(usage) do
    with {:ok, data} <- DagPayload.validate(data, max_bytes: 200_000),
         {:ok, usage} <- normalize_usage(usage),
         {:ok, checksum} <- DagPayload.digest(data),
         result <- %{
           "contract" => contract,
           "version" => @version,
           "artifact" => %{
             "kind" => artifact_kind,
             "media_type" => "application/json",
             "checksum" => "sha256:" <> checksum
           },
           "data" => data,
           "usage" => usage
         },
         {:ok, result} <- DagPayload.validate(result, max_bytes: @max_output_bytes) do
      {:ok, result}
    end
  end

  def wrap(_contract, _artifact_kind, _data, _usage), do: {:error, :invalid_research_output}

  @spec dependency(map(), String.t()) :: {:ok, envelope()} | {:error, term()}
  def dependency(context, contract) do
    case dependencies(context, contract) do
      [result] -> {:ok, result}
      [] -> {:error, {:missing_dependency_contract, contract}}
      _results -> {:error, {:ambiguous_dependency_contract, contract}}
    end
  end

  @spec dependencies(map(), String.t()) :: [envelope()]
  def dependencies(context, contract) do
    context
    |> Map.get(:dependency_results, %{})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      {_key, %{"contract" => ^contract, "version" => @version} = result} -> [result]
      _other -> []
    end)
  end

  @spec data(envelope()) :: map()
  def data(%{"data" => data}) when is_map(data), do: data
  def data(_result), do: %{}

  @spec checkpoint(map(), map(), non_neg_integer()) :: :ok | {:error, term()}
  def checkpoint(context, checkpoint, progress) do
    cond do
      cancelled?(context) ->
        {:error, :cancelled}

      is_function(context[:checkpoint_callback], 2) ->
        context.checkpoint_callback.(checkpoint, progress)

      true ->
        :ok
    end
  end

  @spec cancelled?(map()) :: boolean()
  def cancelled?(context) do
    case context[:cancelled?] do
      fun when is_function(fun, 0) -> safe_cancelled(fun)
      _other -> true
    end
  end

  @spec exact_fields(map(), [String.t()]) :: :ok | {:error, term()}
  def exact_fields(params, fields) when is_map(params) do
    actual = params |> Map.keys() |> Enum.sort()
    expected = Enum.sort(fields)
    if actual == expected, do: :ok, else: {:error, {:params, :invalid_fields}}
  end

  def exact_fields(_params, _fields), do: {:error, {:params, :invalid}}

  @spec bounded_string(term(), pos_integer(), atom()) :: :ok | {:error, term()}
  def bounded_string(value, max, _field)
      when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max,
      do: :ok

  def bounded_string(_value, _max, field), do: {:error, {:params, field}}

  @spec integer(term(), Range.t(), atom()) :: :ok | {:error, term()}
  def integer(value, %Range{first: first, last: last}, _field)
      when is_integer(value) and value >= first and value <= last,
      do: :ok

  def integer(_value, _range, field), do: {:error, {:params, field}}

  @spec boolean(term(), atom()) :: :ok | {:error, term()}
  def boolean(value, _field) when is_boolean(value), do: :ok
  def boolean(_value, field), do: {:error, {:params, field}}

  @spec level_policy(term()) :: :ok | {:error, term()}
  def level_policy(value), do: LevelPolicy.validate_durable(value)

  @spec string_list(term(), non_neg_integer(), pos_integer(), atom()) ::
          :ok | {:error, term()}
  def string_list(values, max_count, max_bytes, _field)
      when is_list(values) and length(values) <= max_count do
    if Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..max_bytes)),
      do: :ok,
      else: {:error, {:params, :invalid_string_list}}
  end

  def string_list(_values, _max_count, _max_bytes, field), do: {:error, {:params, field}}

  @spec attachment_refs(term()) :: :ok | {:error, term()}
  def attachment_refs(refs) when is_list(refs) and length(refs) <= 12 do
    if Enum.all?(refs, fn
         %{"id" => id, "sha256" => digest} = reference
         when map_size(reference) == 2 and is_integer(id) and id > 0 and is_binary(digest) ->
           Regex.match?(~r/^[0-9a-f]{64}$/, digest)

         _reference ->
           false
       end),
       do: :ok,
       else: {:error, {:params, :attachment_refs}}
  end

  def attachment_refs(_refs), do: {:error, {:params, :attachment_refs}}

  @spec error_code(term()) :: String.t()
  def error_code(reason) when is_atom(reason), do: reason |> Atom.to_string() |> bound_code()

  def error_code({reason, _detail}) when is_atom(reason),
    do: reason |> Atom.to_string() |> bound_code()

  def error_code(_reason), do: "provider_error"

  @spec value(map(), atom()) :: term()
  def value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  def value(_map, _key), do: nil

  defp normalize_usage(usage) do
    allowed = ~w(input_tokens output_tokens cost_cents request_count latency_ms search_calls)

    normalized =
      usage
      |> Enum.flat_map(fn {key, value} ->
        key = to_string(key)
        if key in allowed and is_integer(value) and value >= 0, do: [{key, value}], else: []
      end)
      |> Map.new()

    if map_size(normalized) == map_size(usage),
      do: DagPayload.validate(normalized, max_bytes: 8_000),
      else: {:error, :invalid_research_usage}
  end

  defp safe_cancelled(fun) do
    fun.() == true
  rescue
    _error -> true
  catch
    _kind, _reason -> true
  end

  defp bound_code(value) do
    value = String.replace(value, ~r/[^a-z0-9_.:-]/, "_")
    String.slice(value, 0, 80)
  end
end
