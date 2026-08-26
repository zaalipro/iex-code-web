defmodule IexCode.Research.Providers do
  @moduledoc false

  alias IexCode.Research.Result

  def results(provider, rows, mapper) when is_list(rows) do
    rows
    |> Enum.map(mapper)
    |> Enum.map(&Result.new(provider, &1))
    |> Enum.reject(&is_nil/1)
  end

  def results(_provider, _rows, _mapper), do: []

  def api_key(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  def text(nil), do: nil
  def text(value) when is_binary(value), do: value
  def text(value) when is_list(value), do: Enum.join(value, " … ")
  def text(value), do: to_string(value)

  @doc false
  def optional_country(nil), do: {:ok, nil}

  def optional_country(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[A-Za-z]{2}$/, value),
      do: {:ok, value},
      else: {:error, :invalid_country}
  end

  def optional_country(_value), do: {:error, :invalid_country}

  @doc false
  def optional_boolean(nil, _error), do: {:ok, nil}
  def optional_boolean(value, _error) when is_boolean(value), do: {:ok, value}
  def optional_boolean(_value, error), do: {:error, error}

  @doc false
  def optional_string(nil, _max, _error), do: {:ok, nil}

  def optional_string(value, max, error) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= max and String.printable?(value),
      do: {:ok, value},
      else: {:error, error}
  end

  def optional_string(_value, _max, error), do: {:error, error}

  @doc false
  def optional_enum(nil, _allowed, _error), do: {:ok, nil}

  def optional_enum(value, allowed, error) do
    value = if is_atom(value), do: Atom.to_string(value), else: value
    if value in allowed, do: {:ok, value}, else: {:error, error}
  end

  @doc false
  def language_filter(nil), do: {:ok, nil}
  def language_filter(value) when is_binary(value), do: language_filter([value])

  def language_filter(values) when is_list(values) and length(values) <= 20 do
    if Enum.all?(values, &(is_binary(&1) and Regex.match?(~r/^[A-Za-z]{2}$/, &1))) do
      {:ok, Enum.map(values, &String.downcase/1)}
    else
      {:error, :invalid_language_filter}
    end
  end

  def language_filter(_values), do: {:error, :invalid_language_filter}

  @doc false
  def domain_filters(include_domains, exclude_domains, opts \\ []) do
    mutually_exclusive? = Keyword.get(opts, :mutually_exclusive, false)
    max = Keyword.get(opts, :max, 100)

    with {:ok, included} <- domain_filter(include_domains, max),
         {:ok, excluded} <- domain_filter(exclude_domains, max),
         false <- mutually_exclusive? and included not in [nil, []] and excluded not in [nil, []] do
      {:ok, included, excluded}
    else
      true -> {:error, :conflicting_domain_filters}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def optional_date(nil, _format, _error), do: {:ok, nil}

  def optional_date(value, format, error) when is_binary(value) do
    if valid_date?(value, format), do: {:ok, value}, else: {:error, error}
  end

  def optional_date(_value, _format, error), do: {:error, error}

  defp domain_filter(nil, _max), do: {:ok, nil}
  defp domain_filter([], _max), do: {:ok, nil}

  defp domain_filter(values, max) when is_list(values) and length(values) <= max do
    values = Enum.map(values, &normalize_domain/1)

    if Enum.all?(values, &is_binary/1),
      do: {:ok, Enum.uniq(values)},
      else: {:error, :invalid_domain_filter}
  end

  defp domain_filter(_values, _max), do: {:error, :invalid_domain_filter}

  defp normalize_domain(value) when is_binary(value) do
    domain = value |> String.trim() |> String.downcase()

    valid? =
      byte_size(domain) <= 253 and String.contains?(domain, ".") and
        not String.contains?(domain, ["://", "/", "@", " "]) and
        domain
        |> String.split(".")
        |> Enum.all?(fn label ->
          byte_size(label) <= 63 and
            Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, label)
        end)

    if valid?, do: domain
  end

  defp normalize_domain(_value), do: nil

  defp valid_date?(value, :iso8601) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> true
      _ -> false
    end
  end

  defp valid_date?(value, :mdy) do
    with true <- Regex.match?(~r/^\d{2}\/\d{2}\/\d{4}$/, value),
         [month, day, year] <- String.split(value, "/"),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {year, ""} <- Integer.parse(year),
         {:ok, _date} <- Date.new(year, month, day) do
      true
    else
      _ -> false
    end
  end
end
