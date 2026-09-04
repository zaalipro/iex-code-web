defmodule IexCode.Workflows.VariableInterpolatorTest do
  use ExUnit.Case, async: true

  alias IexCode.Workflows.VariableInterpolator

  describe "interpolate/2 and type preservation" do
    test "interpolates simple string variables" do
      context = %{"name" => "Phoenix", "version" => "1.8"}

      assert {:ok, "Welcome to Phoenix v1.8"} =
               VariableInterpolator.interpolate("Welcome to {{name}} v{{version}}", context)
    end

    test "preserves list type when the expression is solely the variable placeholder" do
      files = ["lib/foo.ex", "lib/bar.ex", "test/foo_test.exs"]
      context = %{"target_files" => files}

      assert {:ok, result} = VariableInterpolator.interpolate("{{target_files}}", context)
      assert result == files
      assert is_list(result)
    end

    test "preserves map and integer types for exact variable matches" do
      context = %{
        "config" => %{"max_retries" => 3, "timeout" => 5000},
        "count" => 42,
        "enabled" => true
      }

      assert {:ok, %{"max_retries" => 3, "timeout" => 5000}} =
               VariableInterpolator.interpolate("{{config}}", context)

      assert {:ok, 42} = VariableInterpolator.interpolate("{{count}}", context)
      assert {:ok, true} = VariableInterpolator.interpolate("{{enabled}}", context)
    end

    test "serializes complex structures to JSON when embedded in surrounding text" do
      context = %{"items" => ["apple", "banana"]}

      assert {:ok, "Cart: [\"apple\",\"banana\"] items"} =
               VariableInterpolator.interpolate("Cart: {{items}} items", context)
    end

    test "resolves nested step outputs via dot notation" do
      context = %{
        "steps" => %{
          "research" => %{
            "output" => %{
              "report" => "OAuth2 PKCE Architecture Guide",
              "confidence" => 0.98
            }
          }
        }
      }

      assert {:ok, "OAuth2 PKCE Architecture Guide"} =
               VariableInterpolator.interpolate("{{steps.research.output.report}}", context)

      assert {:ok, 0.98} =
               VariableInterpolator.interpolate("{{steps.research.output.confidence}}", context)
    end

    test "falls back to lookup inside inputs map" do
      context = %{
        "inputs" => %{
          "feature_name" => "Authentication",
          "target_branch" => "main"
        }
      }

      assert {:ok, "Implementing Authentication on branch main"} =
               VariableInterpolator.interpolate(
                 "Implementing {{feature_name}} on branch {{target_branch}}",
                 context
               )
    end

    test "recursively traverses nested maps and lists" do
      context = %{
        "module_name" => "UserAuth",
        "file" => "lib/auth.ex"
      }

      template = %{
        "title" => "Build {{module_name}}",
        "nested" => %{
          "target" => "{{file}}",
          "actions" => ["create {{file}}", "test {{module_name}}"]
        }
      }

      expected = %{
        "title" => "Build UserAuth",
        "nested" => %{
          "target" => "lib/auth.ex",
          "actions" => ["create lib/auth.ex", "test UserAuth"]
        }
      }

      assert {:ok, ^expected} = VariableInterpolator.interpolate(template, context)
    end

    test "retains unresolved variable placeholders when missing from context" do
      context = %{"known" => "yes"}

      assert {:ok, "Known: yes, Unknown: {{unknown_var}}"} =
               VariableInterpolator.interpolate(
                 "Known: {{known}}, Unknown: {{unknown_var}}",
                 context
               )
    end
  end

  describe "missing_variables/2" do
    test "identifies all unresolved variables in template" do
      context = %{"present" => "value"}

      template = %{
        "step_1" => "Use {{present}} and {{missing_one}}",
        "step_2" => ["Also {{missing_two}}", "{{present}}"]
      }

      missing = VariableInterpolator.missing_variables(template, context)
      assert Enum.sort(missing) == ["missing_one", "missing_two"]
    end
  end
end
