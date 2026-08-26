import Config

config :iex_code,
  secure_session_cookie: true

config :iex_code, IexCodeWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Phoenix compiles the SSL redirect plug into the endpoint. Set PHX_FORCE_SSL
# while building the release when TLS is terminated by a trusted proxy. Direct
# HTTP/IP installations must leave it false and set PHX_SCHEME=http at runtime.
force_ssl? =
  case System.get_env("PHX_FORCE_SSL", "false") do
    value when value in ["1", "true", "TRUE"] ->
      true

    value when value in ["0", "false", "FALSE"] ->
      false

    value ->
      raise "environment variable PHX_FORCE_SSL must be true or false, got: #{inspect(value)}"
  end

config :iex_code, IexCodeWeb.Endpoint,
  force_ssl:
    if(force_ssl?,
      do: [rewrite_on: [:x_forwarded_proto], hsts: true],
      else: false
    )

config :logger, level: :info
