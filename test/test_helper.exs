ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(IexCode.Repo, :manual)

admin_token = "iex-code-test-admin-token"

System.put_env(
  "IEX_CODE_ADMIN_TOKEN_SHA256",
  admin_token |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
)
