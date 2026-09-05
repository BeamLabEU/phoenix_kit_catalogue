defmodule PhoenixKitCatalogue.MigrationsTest do
  use ExUnit.Case, async: true

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
end
