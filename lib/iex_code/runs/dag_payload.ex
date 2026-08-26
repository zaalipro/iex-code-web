defmodule IexCode.Runs.DagPayload do
  @moduledoc "Bounded JSON-only, secret-rejecting payload contract for DAG rows."

  @default_max_bytes 64_000
  @max_depth 12
  @max_collection 512
  @secret_names ~w(secret secrets password passwords credential credentials capability capabilities token api_key private_key access_token auth_token capability_token authorization)
  @secret_suffixes ~w(_secret _password _credential _capability _token _api_key _private_key)

  def validate(value, opts \\ []) do
    maximum = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with :ok <- validate_json(value, 0),
         true <- not secret_shaped?(value) or {:error, :secret_payload_forbidden},
         {:ok, encoded} <- canonical_json(value),
         true <- byte_size(encoded) <= maximum or {:error, {:payload_too_large, maximum}} do
      {:ok, value}
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_payload}
    end
  end

  def digest(value) do
    with {:ok, encoded} <- canonical_json(value) do
      {:ok,
       :crypto.hash(:sha256, "iex-code/dag-payload/v1\0" <> encoded)
       |> Base.encode16(case: :lower)}
    end
  end

  def canonical_json(value), do: encode(value)

  defp validate_json(_value, depth) when depth > @max_depth,
    do: {:error, {:json_depth_exceeded, @max_depth}}

  defp validate_json(value, _depth)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_integer(value),
       do: :ok

  defp validate_json(value, _depth) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> :ok
      {:error, _reason} -> {:error, :invalid_json_number}
    end
  end

  defp validate_json(values, depth) when is_list(values) do
    if length(values) <= @max_collection,
      do: reduce_json(values, depth + 1),
      else: {:error, {:json_collection_too_large, @max_collection}}
  end

  defp validate_json(map, depth) when is_map(map) and not is_struct(map) do
    cond do
      map_size(map) > @max_collection ->
        {:error, {:json_collection_too_large, @max_collection}}

      Enum.any?(Map.keys(map), &(not is_binary(&1) or byte_size(&1) not in 1..160)) ->
        {:error, :json_keys_must_be_bounded_strings}

      true ->
        reduce_json(Map.values(map), depth + 1)
    end
  end

  defp validate_json(_value, _depth), do: {:error, :invalid_json}

  defp reduce_json(values, depth) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate_json(value, depth) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp secret_shaped?(map) when is_map(map) and not is_struct(map) do
    Enum.any?(map, fn {key, value} -> secret_key?(key) or secret_shaped?(value) end)
  end

  defp secret_shaped?(list) when is_list(list), do: Enum.any?(list, &secret_shaped?/1)
  defp secret_shaped?(_value), do: false

  defp secret_key?(key) when is_binary(key) do
    normalized =
      key
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")

    normalized in @secret_names or Enum.any?(@secret_suffixes, &String.ends_with?(normalized, &1))
  end

  defp secret_key?(_key), do: false

  defp encode(nil), do: {:ok, "null"}
  defp encode(true), do: {:ok, "true"}
  defp encode(false), do: {:ok, "false"}
  defp encode(value) when is_binary(value), do: Jason.encode(value)
  defp encode(value) when is_integer(value) or is_float(value), do: Jason.encode(value)

  defp encode(values) when is_list(values) do
    with {:ok, encoded} <- encode_many(values) do
      {:ok, "[" <> Enum.join(encoded, ",") <> "]"}
    end
  end

  defp encode(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, encoded} ->
      with true <- is_binary(key),
           {:ok, encoded_key} <- Jason.encode(key),
           {:ok, encoded_value} <- encode(value) do
        {:cont, {:ok, [encoded_key <> ":" <> encoded_value | encoded]}}
      else
        _error -> {:halt, {:error, :invalid_json}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, "{" <> (reversed |> Enum.reverse() |> Enum.join(",")) <> "}"}
      {:error, _reason} = error -> error
    end
  end

  defp encode(_value), do: {:error, :invalid_json}

  defp encode_many(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, encoded} ->
      case encode(value) do
        {:ok, item} -> {:cont, {:ok, [item | encoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end
end
