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

  test "chain is V2 and marks phoenix_kit_cat_catalogues" do
    assert Migrations.current_version() == 2
    assert Migrations.version_table() == "phoenix_kit_cat_catalogues"
  end

  test "up_statements creates every owned table idempotently and stamps the marker" do
    stmts = Migrations.up_statements("public")

    for t <- @tables do
      assert Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} (")),
             "missing CREATE TABLE for #{t}"
    end

    assert List.last(stmts) ==
             "COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS 'pkc_schema:2'"
  end

  test "no statement can destroy data, in either direction" do
    all = Migrations.up_statements("public") ++ Migrations.down_statements("public", 0)

    for s <- all do
      # `ON DELETE CASCADE|RESTRICT|SET NULL` is core's own FK referential
      # action, copied verbatim from the dump authority — not a DROP/
      # TRUNCATE/DELETE statement. The slug projection sync function's
      # own `DELETE FROM <projection> WHERE <owner>_uuid = NEW.uuid` is
      # the one allowed DELETE (core's own `ShopSlugProjection`
      # precedent) — it only ever clears rows of the projection it is
      # about to re-insert, never a base table. `DROP TRIGGER IF
      # EXISTS ... ON <table>` drops a schema object (the trigger),
      # never data, and is the Global Constraints' own idempotent-chain
      # idiom for replacing a trigger definition. Strip all three
      # before scanning for the real destructive verbs the Global
      # Constraints forbid.
      scanned =
        s
        |> (&Regex.replace(
              ~r/ON DELETE (CASCADE|RESTRICT|SET NULL|SET DEFAULT|NO ACTION)/i,
              &1,
              ""
            )).()
        |> (&Regex.replace(
              ~r/DELETE FROM \S+phoenix_kit_cat_(item|category)_slugs WHERE \S+_uuid = NEW\.uuid;/i,
              &1,
              ""
            )).()
        |> (&Regex.replace(~r/DROP TRIGGER IF EXISTS \S+ ON \S+/i, &1, "")).()

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

  # Verbatim from `psql \d <table>` on the live decor3dprint_test database
  # (18 tables, read-only cross-check — no writes) — all 40 index names
  # this chain owns. A prior version of "every CREATE INDEX ... is
  # guarded" above stayed green with all 40 deleted, because it only
  # scans statements that already exist; this pins the actual set.
  @indexes ~w(
    phoenix_kit_cat_attribute_values_attr_key_index
    phoenix_kit_cat_attribute_values_attr_position_index
    phoenix_kit_cat_attribute_values_default_index
    phoenix_kit_cat_attributes_group_key_index
    phoenix_kit_cat_attributes_group_position_index
    phoenix_kit_cat_catalogues_folder_uuid_index
    phoenix_kit_cat_catalogues_kind_smart_index
    phoenix_kit_cat_catalogues_status_index
    phoenix_kit_cat_categories_catalogue_uuid_index
    phoenix_kit_cat_categories_catalogue_uuid_position_index
    phoenix_kit_cat_categories_parent_index
    phoenix_kit_cat_categories_status_index
    phoenix_kit_cat_folders_parent_uuid_position_index
    phoenix_kit_cat_folders_status_index
    phoenix_kit_cat_item_attr_groups_group_index
    phoenix_kit_cat_item_attr_groups_item_index
    phoenix_kit_cat_item_attribute_sets_set_uuid_index
    phoenix_kit_cat_item_catalogue_rules_item_index
    phoenix_kit_cat_item_catalogue_rules_pair_index
    phoenix_kit_cat_item_catalogue_rules_referenced_index
    phoenix_kit_cat_item_supplier_info_current_pair_uniq
    phoenix_kit_cat_item_supplier_info_item_index
    phoenix_kit_cat_item_supplier_info_primary_uniq
    phoenix_kit_cat_item_supplier_info_supplier_index
    phoenix_kit_cat_items_catalogue_uuid_index
    phoenix_kit_cat_items_catalogue_uuid_status_index
    phoenix_kit_cat_items_category_uuid_index
    phoenix_kit_cat_items_manufacturer_uuid_index
    phoenix_kit_cat_items_primary_supplier_uuid_index
    phoenix_kit_cat_items_status_index
    phoenix_kit_cat_manufacturer_suppliers_manufacturer_uuid_suppli
    phoenix_kit_cat_manufacturers_crm_company_uuid_index
    phoenix_kit_cat_manufacturers_status_index
    phoenix_kit_cat_pdf_extractions_extraction_status_index
    phoenix_kit_cat_pdf_page_contents_text_trgm_index
    phoenix_kit_cat_pdf_pages_content_hash_index
    phoenix_kit_cat_pdfs_file_uuid_index
    phoenix_kit_cat_pdfs_status_index
    phoenix_kit_cat_suppliers_crm_company_uuid_index
    phoenix_kit_cat_suppliers_status_index
    phoenix_kit_cat_item_slugs_item_uuid_idx
    phoenix_kit_cat_category_slugs_category_uuid_idx
    phoenix_kit_cat_item_attribute_sets_selected_values_gin
  )

  # Same source, all 50 constraint names (18 PKs + 19 FKs + 13 CHECKs).
  @constraints ~w(
    phoenix_kit_cat_catalogues_pkey
    phoenix_kit_cat_folders_pkey
    phoenix_kit_cat_categories_pkey
    phoenix_kit_cat_manufacturers_pkey
    phoenix_kit_cat_suppliers_pkey
    phoenix_kit_cat_manufacturer_suppliers_pkey
    phoenix_kit_cat_items_pkey
    phoenix_kit_cat_item_catalogue_rules_pkey
    phoenix_kit_cat_item_supplier_info_pkey
    phoenix_kit_cat_pdf_page_contents_pkey
    phoenix_kit_cat_pdfs_pkey
    phoenix_kit_cat_pdf_pages_pkey
    phoenix_kit_cat_pdf_extractions_pkey
    phoenix_kit_cat_attribute_groups_pkey
    phoenix_kit_cat_attributes_pkey
    phoenix_kit_cat_attribute_values_pkey
    phoenix_kit_cat_item_attribute_groups_pkey
    phoenix_kit_cat_item_attribute_sets_pkey
    phoenix_kit_cat_attribute_values_attribute_uuid_fkey
    phoenix_kit_cat_attributes_group_uuid_fkey
    phoenix_kit_cat_catalogues_folder_uuid_fkey
    phoenix_kit_cat_categories_catalogue_uuid_fkey
    phoenix_kit_cat_categories_parent_uuid_fkey
    phoenix_kit_cat_folders_parent_uuid_fkey
    phoenix_kit_cat_item_attribute_groups_attribute_group_uuid_fkey
    phoenix_kit_cat_item_attribute_groups_item_uuid_fkey
    phoenix_kit_cat_item_attribute_sets_item_uuid_fkey
    phoenix_kit_cat_item_catalogue_r_referenced_catalogue_uuid_fkey
    phoenix_kit_cat_item_catalogue_rules_item_uuid_fkey
    phoenix_kit_cat_item_supplier_info_item_uuid_fkey
    phoenix_kit_cat_items_catalogue_uuid_fkey
    phoenix_kit_cat_items_category_uuid_fkey
    phoenix_kit_cat_items_primary_supplier_uuid_fkey
    phoenix_kit_cat_pdf_extractions_file_uuid_fkey
    phoenix_kit_cat_pdf_pages_content_hash_fkey
    phoenix_kit_cat_pdf_pages_file_uuid_fkey
    phoenix_kit_cat_pdfs_file_uuid_fkey
    phoenix_kit_cat_catalogues_discount_pct_check
    phoenix_kit_cat_catalogues_kind_check
    phoenix_kit_cat_manufacturer_suppliers_mfr_source_check
    phoenix_kit_cat_manufacturer_suppliers_sup_source_check
    phoenix_kit_cat_items_default_value_check
    phoenix_kit_cat_items_discount_pct_check
    phoenix_kit_cat_items_manufacturer_source_check
    phoenix_kit_cat_item_catalogue_rules_value_check
    phoenix_kit_cat_item_supplier_info_supplier_source_check
    phoenix_kit_cat_attribute_groups_status_check
    phoenix_kit_cat_attributes_kind_check
    phoenix_kit_cat_attributes_status_check
    phoenix_kit_cat_attribute_values_status_check
  )

  test "every pinned index name appears inside a CREATE ... IF NOT EXISTS statement" do
    stmts = Migrations.up_statements("public")

    for name <- @indexes do
      assert Enum.any?(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS #{name}\b/)),
             "missing guarded index #{name}"
    end

    assert length(@indexes) ==
             Enum.count(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/))
  end

  test "every pinned constraint name appears inside a guarded DO $$ block" do
    stmts = Migrations.up_statements("public")

    for name <- @constraints do
      assert Enum.any?(stmts, fn s -> s =~ ~r/DO \$\$/ and s =~ ~r/ADD CONSTRAINT #{name}\b/ end),
             "missing guarded constraint #{name}"
    end

    assert length(@constraints) == Enum.count(stmts, &(&1 =~ ~r/DO \$\$/))
  end

  test "down only rewrites the marker" do
    assert Migrations.down_statements("public", 0) ==
             ["COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS NULL"]

    assert Migrations.down_statements("public", 1) ==
             ["COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS 'pkc_schema:1'"]
  end

  @v2_tables ~w(phoenix_kit_cat_item_slugs phoenix_kit_cat_category_slugs)
  @v2_functions ~w(sync_cat_item_slugs sync_cat_category_slugs)
  @v2_triggers ~w(trg_cat_item_slugs trg_cat_category_slugs)

  test "V2 adds the slug column, the projections and the GIN index" do
    joined = Enum.join(Migrations.up_statements("public"), "\n")

    for t <- ~w(phoenix_kit_cat_items phoenix_kit_cat_categories) do
      assert joined =~
               "ALTER TABLE public.#{t} ADD COLUMN IF NOT EXISTS slug jsonb DEFAULT '{}'::jsonb NOT NULL"
    end

    for t <- @v2_tables, do: assert(joined =~ "CREATE TABLE IF NOT EXISTS public.#{t} (")

    for f <- @v2_functions,
        do: assert(joined =~ "CREATE OR REPLACE FUNCTION public.#{f}() RETURNS trigger")

    for tr <- @v2_triggers, do: assert(joined =~ "CREATE TRIGGER #{tr}\n")

    assert joined =~
             "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_attribute_sets_selected_values_gin ON public.phoenix_kit_cat_item_attribute_sets USING gin ((data -> 'selected_value_slugs'))"

    assert List.last(Migrations.up_statements("public")) ==
             "COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS 'pkc_schema:2'"
  end

  test "down to 1 only re-stamps the marker" do
    assert Migrations.down_statements("public", 1) == [
             "COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS 'pkc_schema:1'"
           ]
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
