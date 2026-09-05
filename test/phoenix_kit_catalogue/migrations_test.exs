defmodule PhoenixKitCatalogue.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema.Resolver
  alias PhoenixKitCatalogue.Migrations

  @tables ~w(
    phoenix_kit_cat_catalogues
    phoenix_kit_cat_categories
    phoenix_kit_cat_items
    phoenix_kit_cat_manufacturers
    phoenix_kit_cat_manufacturer_suppliers
    phoenix_kit_cat_suppliers
    phoenix_kit_cat_folders
    phoenix_kit_cat_item_catalogue_rules
    phoenix_kit_cat_pdfs
    phoenix_kit_cat_pdf_pages
    phoenix_kit_cat_pdf_page_contents
    phoenix_kit_cat_pdf_extractions
    phoenix_kit_cat_item_supplier_info
    phoenix_kit_cat_attribute_groups
    phoenix_kit_cat_attributes
    phoenix_kit_cat_attribute_values
    phoenix_kit_cat_item_attribute_groups
    phoenix_kit_cat_item_attribute_sets
  )

  test "chain is V1 and marks phoenix_kit_cat_catalogues" do
    assert Migrations.current_version() == 1
    assert Migrations.version_table() == "phoenix_kit_cat_catalogues"
  end

  test "up_statements creates every owned table idempotently and stamps the marker" do
    stmts = Migrations.up_statements("public")

    for t <- @tables do
      assert Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} (")),
             "missing CREATE TABLE for #{t}"
    end

    assert List.last(stmts) ==
             "COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS 'pkc_schema:1'"
  end

  test "no statement can destroy data, in either direction" do
    all = Migrations.up_statements("public") ++ Migrations.down_statements("public", 0)

    for s <- all do
      # `ON DELETE CASCADE|RESTRICT|SET NULL` is core's own FK referential
      # action, copied verbatim from the dump authority — not a DROP/
      # TRUNCATE/DELETE statement. Strip it before scanning for the real
      # destructive verbs the Global Constraints forbid.
      scanned =
        Regex.replace(~r/ON DELETE (CASCADE|RESTRICT|SET NULL|SET DEFAULT|NO ACTION)/i, s, "")

      refute scanned =~ ~r/\b(DROP|TRUNCATE|DELETE)\b/i, "destructive statement: #{s}"
      refute scanned =~ ~r/ALTER TABLE .* DROP/i, "destructive statement: #{s}"
    end
  end

  test "every CREATE INDEX and constraint is guarded" do
    for s <- Migrations.up_statements("public"), s =~ ~r/CREATE (UNIQUE )?INDEX/ do
      assert s =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/
    end

    for s <- Migrations.up_statements("public"), s =~ ~r/ADD CONSTRAINT/ do
      assert s =~ ~r/DO \$\$/ and s =~ ~r/IF NOT EXISTS/
    end
  end

  test "down only rewrites the marker" do
    assert Migrations.down_statements("public", 0) ==
             ["COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS NULL"]

    assert Migrations.down_statements("public", 1) ==
             ["COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS 'pkc_schema:1'"]
  end

  test "prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP") end
  end

  test "the module registers the chain" do
    assert PhoenixKitCatalogue.migration_module() == Migrations
  end

  test "parents are created before children (FK targets exist first)" do
    stmts = Migrations.up_statements("public")

    idx = fn t ->
      Enum.find_index(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} ("))
    end

    assert idx.("phoenix_kit_cat_catalogues") < idx.("phoenix_kit_cat_categories")
    assert idx.("phoenix_kit_cat_categories") < idx.("phoenix_kit_cat_items")
    assert idx.("phoenix_kit_cat_manufacturers") < idx.("phoenix_kit_cat_items")
    assert idx.("phoenix_kit_cat_suppliers") < idx.("phoenix_kit_cat_item_supplier_info")
    assert idx.("phoenix_kit_cat_pdf_page_contents") < idx.("phoenix_kit_cat_pdf_pages")
    assert idx.("phoenix_kit_cat_items") < idx.("phoenix_kit_cat_item_attribute_sets")
  end

  # ── the drift lock ───────────────────────────────────────────────────
  #
  # Core's `ExpectedSchema` manifest is the audit authority for every
  # `phoenix_kit_cat_*` object, and V01 only holds together while this
  # chain reproduces exactly what that manifest describes. Nothing else
  # pins that: a core release that adds a column to an adopted table
  # leaves this chain quietly building the older shape on fresh installs,
  # and the string tests above all still pass. Compare the two lists.
  #
  # Resolved through `Resolver` rather than the manifest module directly —
  # `mix.exs` floors core at `~> 2.8` and the manifest only ships in later
  # releases, so "not generated" is an ordinary condition here, not a
  # failure.
  describe "core's ExpectedSchema manifest" do
    setup do
      case Resolver.resolve() do
        {:ok, manifest} -> {:ok, objects: catalogue_objects(manifest)}
        {:error, :not_generated} -> {:ok, objects: nil}
      end
    end

    test "every required catalogue-owned object is emitted by up_statements/1", ctx do
      if ctx.objects do
        # A manifest that resolved but tagged nothing `owner: :catalogue`
        # (a renamed owner atom upstream) would make every assertion in
        # this describe block pass on an empty list.
        refute ctx.objects == []

        stmts = Migrations.up_statements("public")

        missing =
          ctx.objects
          |> Enum.filter(&(&1.presence == :required))
          |> Enum.reject(&emitted?(stmts, &1))
          |> Enum.map(& &1.id)

        assert missing == [],
               "core's manifest requires these on a fresh install, and the chain " <>
                 "does not create them:\n  " <> Enum.join(missing, "\n  ")
      end
    end

    test "the constraints core's own chain dropped are NOT re-created", ctx do
      if ctx.objects do
        stmts = Migrations.up_statements("public")

        # V179/V180 dropped the manufacturer FKs to federate those
        # references onto CRM parties. The manifest carries them as
        # `:legacy_optional` — present only on installs that stopped
        # before those versions. Re-adding one here would pin every
        # item's manufacturer back to a local row.
        resurrected =
          ctx.objects
          |> Enum.filter(&(&1.presence == :legacy_optional and emitted?(stmts, &1)))
          |> Enum.map(& &1.id)

        assert resurrected == [],
               "chain re-creates objects core deliberately dropped:\n  " <>
                 Enum.join(resurrected, "\n  ")
      end
    end
  end

  defp catalogue_objects(manifest) do
    Enum.filter(manifest.objects("public"), &(&1.owner == :catalogue))
  end

  # The manifest's id format (`table:<t>` / `column:<t>.<c>` /
  # `index:<name>` / `constraint:<t>.<name>`) is what identifies the object
  # in the DDL this chain emits.
  defp emitted?(stmts, %{class: :table, id: "table:" <> table}) do
    Enum.any?(stmts, &creates_table?(&1, table))
  end

  defp emitted?(stmts, %{class: :index, id: "index:" <> name}) do
    Enum.any?(stmts, &String.contains?(&1, "INDEX IF NOT EXISTS #{name} ON "))
  end

  defp emitted?(stmts, %{class: :column, id: "column:" <> rest}) do
    [table, column] = String.split(rest, ".", parts: 2)

    stmts
    |> Enum.find(&creates_table?(&1, table))
    |> declared_columns()
    |> Enum.member?(column)
  end

  defp emitted?(stmts, %{class: :constraint, id: "constraint:" <> rest}) do
    [table, name] = String.split(rest, ".", parts: 2)

    Enum.any?(stmts, fn s ->
      String.contains?(s, table) and String.contains?(s, "CONSTRAINT #{name} ")
    end)
  end

  defp creates_table?(statement, table) do
    String.contains?(statement, "CREATE TABLE IF NOT EXISTS public.#{table} (")
  end

  defp declared_columns(nil), do: []

  defp declared_columns(statement) do
    statement
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["CREATE ", "CONSTRAINT ", ")"])))
    |> Enum.map(fn line -> line |> String.split(" ", parts: 2) |> hd() |> String.trim("\"") end)
  end
end
