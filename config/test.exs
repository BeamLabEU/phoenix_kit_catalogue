import Config

config :phoenix_kit_catalogue, ecto_repos: [PhoenixKitCatalogue.Test.Repo]

config :phoenix_kit_catalogue, PhoenixKitCatalogue.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_catalogue_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  priv: "test/support/postgres"

# Wire repo for library code that calls PhoenixKit.RepoHelper.repo()
config :phoenix_kit, repo: PhoenixKitCatalogue.Test.Repo

# Test Endpoint + LiveView for web tests. `phoenix_kit_catalogue` has
# no endpoint of its own in production — the host app provides one —
# so this tiny endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_catalogue, PhoenixKitCatalogue.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "catalogue-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitCatalogue.Test.Layouts]],
  # Required by Phoenix.LiveViewTest's UploadClient when exercising
  # `file_input/3` + `render_upload/3` against the test Endpoint.
  pubsub_server: PhoenixKit.PubSub

config :phoenix, :json_library, Jason

config :logger, level: :warning
