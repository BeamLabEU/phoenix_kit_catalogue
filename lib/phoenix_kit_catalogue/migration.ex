defmodule PhoenixKitCatalogue.Migrations do
  @moduledoc false

  defdelegate up(opts \\ []), to: PhoenixKitCatalogue.Migration
  defdelegate down(opts \\ []), to: PhoenixKitCatalogue.Migration
end

defmodule PhoenixKitCatalogue.Migration do
  @moduledoc """
  Versioned migrations for the Catalogue module.

  ## Usage

  Create a migration in your parent app:

      defmodule MyApp.Repo.Migrations.AddCatalogueTables do
        use Ecto.Migration

        def up, do: PhoenixKitCatalogue.Migration.up()
        def down, do: PhoenixKitCatalogue.Migration.down()
      end

  Migrations are versioned and idempotent. Running `up/1` detects the current
  database version and only applies new migrations.
  """

  use Ecto.Migration

  @initial_version 1
  @current_version 2
  @default_prefix "public"
  @version_table "phoenix_kit_cat_manufacturers"

  @doc "Returns the latest migration version."
  def current_version, do: @current_version

  @doc "Run migrations up to the latest (or specified) version."
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 ->
        change(@initial_version..opts.version, :up, opts)

      initial < opts.version ->
        change((initial + 1)..opts.version, :up, opts)

      true ->
        :ok
    end
  end

  @doc "Roll back migrations. Without a `:version` option, rolls back completely."
  def down(opts \\ []) do
    opts =
      opts
      |> Enum.into(%{prefix: @default_prefix})
      |> Map.put_new(:quoted_prefix, inspect(@default_prefix))
      |> Map.put_new(:escaped_prefix, @default_prefix)

    current = migrated_version(opts)
    target = Map.get(opts, :version, 0)

    if current > target do
      change(current..(target + 1)//-1, :down, opts)
    end
  end

  @doc "Returns the current migrated version from the database."
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{@version_table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = '#{@version_table}'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo().query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) ->
            String.to_integer(version)

          _ ->
            1
        end

      _ ->
        0
    end
  end

  @doc "Runtime-safe version of `migrated_version/1`."
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    repo = PhoenixKit.Config.get_repo()

    unless repo do
      raise "Cannot detect repo — ensure PhoenixKit is configured"
    end

    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{@version_table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo.query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = '#{@version_table}'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo.query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) ->
            String.to_integer(version)

          _ ->
            1
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  # ── Internal ──────────────────────────────────────────────────────

  defp change(range, direction, opts) do
    Enum.each(range, fn index ->
      pad = String.pad_leading(to_string(index), 2, "0")

      [PhoenixKitCatalogue.Migration.Postgres, "V#{pad}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end)

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, max(Enum.min(range) - 1, 0))
    end
  end

  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute("COMMENT ON TABLE #{prefix}.#{@version_table} IS '#{version}'")
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
  end
end
