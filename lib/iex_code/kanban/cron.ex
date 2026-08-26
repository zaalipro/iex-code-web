defmodule IexCode.Kanban.Cron do
  @moduledoc """
  Small, dependency-free parser for safe five-field cron schedules.

  Schedules are evaluated in UTC. Fields support `*`, exact values, comma
  lists, inclusive ranges, and steps (`*/15`, `1-5/2`). Month and weekday
  names and non-standard extensions are deliberately rejected.
  """

  @minute_range 0..59
  @hour_range 0..23
  @day_range 1..31
  @month_range 1..12
  @weekday_range 0..7
  @max_search_minutes 2_635_200

  @type parsed :: %{
          minute: MapSet.t(integer()),
          hour: MapSet.t(integer()),
          day: MapSet.t(integer()),
          month: MapSet.t(integer()),
          weekday: MapSet.t(integer()),
          day_wildcard?: boolean(),
          weekday_wildcard?: boolean()
        }

  @doc "Parses a conventional five-field cron expression."
  @spec parse(String.t()) :: {:ok, parsed()} | {:error, :invalid_cron}
  def parse(expression) when is_binary(expression) do
    case String.split(expression, ~r/\s+/, trim: true) do
      [minute, hour, day, month, weekday] ->
        with {:ok, minutes} <- parse_field(minute, @minute_range),
             {:ok, hours} <- parse_field(hour, @hour_range),
             {:ok, days} <- parse_field(day, @day_range),
             {:ok, months} <- parse_field(month, @month_range),
             {:ok, weekdays} <- parse_field(weekday, @weekday_range) do
          parsed = %{
            minute: minutes,
            hour: hours,
            day: days,
            month: months,
            weekday: normalize_weekdays(weekdays),
            day_wildcard?: wildcard?(day),
            weekday_wildcard?: wildcard?(weekday)
          }

          if possible_calendar_day?(parsed), do: {:ok, parsed}, else: {:error, :invalid_cron}
        end

      _ ->
        {:error, :invalid_cron}
    end
  end

  def parse(_expression), do: {:error, :invalid_cron}

  @doc "Returns the first matching UTC minute strictly after `after_datetime`."
  @spec next_occurrence(String.t(), DateTime.t(), keyword()) ::
          {:ok, DateTime.t()} | {:error, :invalid_cron | :no_occurrence}
  def next_occurrence(expression, after_datetime, opts \\ [])

  def next_occurrence(expression, %DateTime{} = after_datetime, opts) do
    max_minutes = Keyword.get(opts, :max_search_minutes, @max_search_minutes)

    with {:ok, parsed} <- parse(expression),
         true <- is_integer(max_minutes) and max_minutes > 0 do
      candidate =
        after_datetime
        |> DateTime.shift_zone!("Etc/UTC")
        |> DateTime.truncate(:second)
        |> next_minute()

      find_next(parsed, candidate, max_minutes)
    else
      false -> {:error, :no_occurrence}
      {:error, _} = error -> error
    end
  end

  def next_occurrence(_expression, _after_datetime, _opts), do: {:error, :invalid_cron}

  defp find_next(_parsed, _candidate, 0), do: {:error, :no_occurrence}

  defp find_next(parsed, candidate, remaining) do
    if matches?(parsed, candidate) do
      {:ok, candidate}
    else
      find_next(parsed, DateTime.add(candidate, 60, :second), remaining - 1)
    end
  end

  defp matches?(parsed, datetime) do
    date = DateTime.to_date(datetime)
    cron_weekday = rem(Date.day_of_week(date), 7)
    day_match? = MapSet.member?(parsed.day, date.day)
    weekday_match? = MapSet.member?(parsed.weekday, cron_weekday)

    day_rule_match? =
      cond do
        parsed.day_wildcard? and parsed.weekday_wildcard? -> true
        parsed.day_wildcard? -> weekday_match?
        parsed.weekday_wildcard? -> day_match?
        true -> day_match? or weekday_match?
      end

    MapSet.member?(parsed.minute, datetime.minute) and
      MapSet.member?(parsed.hour, datetime.hour) and
      MapSet.member?(parsed.month, date.month) and day_rule_match?
  end

  defp next_minute(datetime) do
    datetime
    |> DateTime.add(60 - datetime.second, :second)
    |> DateTime.truncate(:second)
  end

  defp parse_field(field, range) do
    field
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn segment, {:ok, values} ->
      case parse_segment(segment, range) do
        {:ok, segment_values} ->
          {:cont, {:ok, Enum.reduce(segment_values, values, &MapSet.put(&2, &1))}}

        :error ->
          {:halt, {:error, :invalid_cron}}
      end
    end)
    |> case do
      {:ok, values} ->
        if(MapSet.size(values) > 0, do: {:ok, values}, else: {:error, :invalid_cron})

      _ ->
        {:error, :invalid_cron}
    end
  end

  defp parse_segment(segment, range) do
    case String.split(segment, "/", parts: 2) do
      [base] -> expand_base(base, range, 1)
      [base, step] -> with {:ok, step} <- parse_step(step), do: expand_stepped(base, range, step)
      _ -> :error
    end
  end

  defp parse_step(step) do
    case Integer.parse(step) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp expand_base("*", range, step), do: {:ok, Enum.take_every(range, step)}

  defp expand_base(base, range, step) do
    case String.split(base, "-", parts: 2) do
      [single] ->
        with {:ok, value} <- parse_value(single),
             true <- value in range do
          {:ok, [value]}
        else
          _ -> :error
        end

      [first, last] ->
        with {:ok, first} <- parse_value(first),
             {:ok, last} <- parse_value(last),
             true <- first in range and last in range and first <= last do
          {:ok, Enum.take_every(first..last, step)}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp expand_stepped("*", range, step), do: expand_base("*", range, step)

  defp expand_stepped(base, range, step) do
    case String.split(base, "-", parts: 2) do
      [first, last] ->
        expand_base("#{first}-#{last}", range, step)

      [first] ->
        with {:ok, first} <- parse_value(first),
             true <- first in range do
          {:ok, Enum.take_every(first..range.last, step)}
        else
          _ -> :error
        end
    end
  end

  defp parse_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp normalize_weekdays(values) do
    Enum.reduce(values, MapSet.new(), fn
      7, acc -> MapSet.put(acc, 0)
      value, acc -> MapSet.put(acc, value)
    end)
  end

  # A restricted weekday is OR-ed with day-of-month by standard cron rules,
  # so it always supplies a possible day. Otherwise validate restricted
  # month/day combinations against a leap year to reject e.g. 31 February.
  defp possible_calendar_day?(%{day_wildcard?: true}), do: true
  defp possible_calendar_day?(%{weekday_wildcard?: false}), do: true

  defp possible_calendar_day?(parsed) do
    Enum.any?(parsed.month, fn month ->
      Enum.any?(parsed.day, fn day -> match?({:ok, _}, Date.new(2024, month, day)) end)
    end)
  end

  defp wildcard?(field), do: String.starts_with?(field, "*")
end
