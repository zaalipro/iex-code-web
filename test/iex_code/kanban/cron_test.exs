defmodule IexCode.Kanban.CronTest do
  use ExUnit.Case, async: true

  alias IexCode.Kanban.Cron

  test "finds common interval, list, range, and weekday schedules in UTC" do
    assert {:ok, ~U[2026-08-23 12:15:00Z]} =
             Cron.next_occurrence("*/15 9-17 * * *", ~U[2026-08-23 12:01:20Z])

    assert {:ok, ~U[2026-08-24 09:00:00Z]} =
             Cron.next_occurrence("0 9,17 * * 1-5", ~U[2026-08-23 20:00:00Z])

    assert {:ok, ~U[2026-09-01 00:00:00Z]} =
             Cron.next_occurrence("0 0 1 * *", ~U[2026-08-23 00:00:00Z])

    assert {:ok, ~U[2026-08-23 12:20:00Z]} =
             Cron.next_occurrence("5/15 * * * *", ~U[2026-08-23 12:06:00Z])
  end

  test "uses conventional OR semantics when both day-of-month and weekday are restricted" do
    assert {:ok, ~U[2026-08-24 08:00:00Z]} =
             Cron.next_occurrence("0 8 1 * 1", ~U[2026-08-23 00:00:00Z])
  end

  test "rejects unsafe or unsupported cron syntax" do
    for expression <- [
          "",
          "* * * *",
          "@daily",
          "0 0 L * *",
          "60 * * * *",
          "*/0 * * * *",
          "0 0 31 2 *"
        ] do
      assert {:error, :invalid_cron} = Cron.parse(expression)
    end
  end
end
