# Elixir 1.19's `mix test` no longer auto-loads modules from the
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Our
# support modules (`PhoenixKitCatalogue.Test.Repo`, `Test.Endpoint`,
# etc.) are compiled but not loaded, so explicit `Code.require_file/2`
# calls are needed before `test_helper.exs` references them.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

# Check if the test database exists
db_name =
  Application.get_env(:phoenix_kit_catalogue, PhoenixKitCatalogue.Test.Repo)[:database] ||
    "phoenix_kit_catalogue_test"

db_check =
  case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `mix test.setup` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitCatalogue.Test.Repo.start_link()

      # `uuid-ossp` provides historical UUID helpers; `pgcrypto` is what
      # `uuid_generate_v7/0` actually needs (gen_random_bytes lives in
      # pgcrypto). Without both extensions, the very first INSERT into a
      # `uuid_generate_v7()`-defaulted table fails with "function
      # gen_random_bytes(integer) does not exist" — and the failure
      # surfaces a long way from the helper's definition. Both
      # extensions are normally created by the host's V40 / pgcrypto
      # migrations; we recreate them here so the test DB is self-sufficient.
      PhoenixKitCatalogue.Test.Repo.query!("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")
      PhoenixKitCatalogue.Test.Repo.query!("CREATE EXTENSION IF NOT EXISTS pgcrypto")

      PhoenixKitCatalogue.Test.Repo.query!("""
      CREATE OR REPLACE FUNCTION uuid_generate_v7()
      RETURNS uuid AS $$
      DECLARE
        unix_ts_ms bytea;
        uuid_bytes bytea;
      BEGIN
        unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
        uuid_bytes := unix_ts_ms || gen_random_bytes(10);
        uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
        uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
        RETURN encode(uuid_bytes, 'hex')::uuid;
      END;
      $$ LANGUAGE plpgsql VOLATILE;
      """)

      # Apply every migration in `test/support/postgres/migrations/`.
      # These mirror the post-V87 catalogue surface (V96 catalogue_uuid /
      # V97 item markup override / V102 smart catalogues / V103 nested
      # categories) plus the `phoenix_kit_settings` table the
      # `enabled?/0` callback reads from. Without this run, every test
      # that touches the V102 `kind` column crashes with
      # `column "kind" does not exist` and every test that reads
      # settings poisons the sandbox transaction.
      Ecto.Migrator.run(
        PhoenixKitCatalogue.Test.Repo,
        Path.join([__DIR__, "support", "postgres", "migrations"]),
        :up,
        all: true,
        log: false
      )

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitCatalogue.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_catalogue, :test_repo_available, repo_available)

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache to an empty string for tests so
# `Paths.index()` etc. produce paths the test router can match. Admin
# paths always get the default locale ("en") prefix, so our router
# scope is `/en/admin/catalogue`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our
# LiveViews via `live/2` with real URLs. Runs with `server: false`, so
# no port is opened.
{:ok, _} = PhoenixKitCatalogue.Test.Endpoint.start_link()

# Start a Phoenix.PubSub registered as `PhoenixKit.PubSub` so the
# catalogue's `Catalogue.PubSub.broadcast/3` calls (fired on every
# mutation) don't crash with "unknown registry". The host app provides
# this in production.
case Phoenix.PubSub.Supervisor.start_link(name: PhoenixKit.PubSub) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start(exclude: exclude)
