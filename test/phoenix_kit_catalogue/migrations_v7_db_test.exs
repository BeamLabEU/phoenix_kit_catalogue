defmodule PhoenixKitCatalogue.MigrationsV7DBTest do
  @moduledoc """
  V7 (numeric dimensions, generated area and volume, pack sizes, cost
  unit) against the real database: a replay is a no-op, the columns land
  with the declared shape, Postgres computes the area and volume exactly,
  and the CHECKs hold. Raw SQL throughout, so it is the database's rules
  that are tested and not the changeset's.
  """

  # async: false — the replay takes table locks for the whole sandboxed
  # transaction, and the CHECK tests abort theirs on purpose.
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Migrations

  defp replay_chain! do
    for stmt <- Migrations.up_statements("public"), do: Repo.query!(stmt)
  end

  defp column(table, name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, numeric_precision, numeric_scale, is_nullable, is_generated
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, name]
      )

    rows
  end

  defp count(sql, params) do
    %{rows: [[count]]} = Repo.query!(sql, params)
    count
  end

  defp set_dimensions(item, length, width, thickness) do
    Repo.query(
      """
      UPDATE phoenix_kit_cat_items
      SET length_mm = $2::text::numeric, width_mm = $3::text::numeric, thickness_mm = $4::text::numeric
      WHERE uuid = $1::text::uuid
      RETURNING area_m2::text, volume_m3::text
      """,
      [item.uuid, length, width, thickness]
    )
  end

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "V7 catalogue"})
    {:ok, item} = Catalogue.create_item(%{name: "Plywood", catalogue_uuid: catalogue.uuid})
    %{catalogue: catalogue, item: item}
  end

  test "replaying the chain twice is idempotent and stamps pkc_schema:7" do
    replay_chain!()
    replay_chain!()

    for name <- ~w(
          phoenix_kit_cat_items_length_mm_check
          phoenix_kit_cat_items_width_mm_check
          phoenix_kit_cat_items_thickness_mm_check
          phoenix_kit_cat_items_pack_size_check
          phoenix_kit_cat_item_supplier_info_pack_size_check
        ) do
      assert count("SELECT count(*) FROM pg_constraint WHERE conname = $1", [name]) == 1, name
    end

    assert count(
             "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
             ["phoenix_kit_cat_items_catalogue_thickness_index"]
           ) == 1

    assert Migrations.migrated_version_runtime(prefix: "public") == 7
  end

  test "the columns have the declared shape" do
    replay_chain!()

    for name <- ~w(length_mm width_mm thickness_mm) do
      assert [["numeric", 10, 3, "YES", "NEVER"]] = column("phoenix_kit_cat_items", name)
    end

    # Unconstrained numeric: the product's own scale, nothing cut off.
    for name <- ~w(area_m2 volume_m3) do
      assert [["numeric", nil, nil, "YES", "ALWAYS"]] = column("phoenix_kit_cat_items", name)
    end

    for table <- ~w(phoenix_kit_cat_items phoenix_kit_cat_item_supplier_info) do
      assert [["numeric", 14, 4, "YES", "NEVER"]] = column(table, "pack_size")
    end

    assert [["character varying", nil, nil, "YES", "NEVER"]] =
             column("phoenix_kit_cat_item_supplier_info", "cost_unit")
  end

  test "Postgres computes the area and volume exactly", %{item: item} do
    assert {:ok, %{rows: [[area, volume]]}} = set_dimensions(item, "2500", "1250", "18")
    assert Decimal.equal?(Decimal.new(area), Decimal.new("3.125"))
    assert Decimal.equal?(Decimal.new(volume), Decimal.new("0.05625"))

    # 6.5 mm keeps its precision.
    assert {:ok, %{rows: [[_area, volume]]}} = set_dimensions(item, "2500", "1250", "6.5")
    assert Decimal.equal?(Decimal.new(volume), Decimal.new("0.0203125"))

    # The largest values the columns take lose no digit either.
    assert {:ok, %{rows: [[area, volume]]}} =
             set_dimensions(item, "9999999.999", "9999999.999", "9999999.999")

    assert area == "99999999.980000000001"
    assert volume == "999999999700.000000029999999999"
  end

  test "an area needs no thickness; a missing dimension leaves the value NULL", %{item: item} do
    assert {:ok, %{rows: [[area, nil]]}} =
             Repo.query(
               """
               UPDATE phoenix_kit_cat_items SET length_mm = 2500, width_mm = 1250
               WHERE uuid = $1::text::uuid RETURNING area_m2::text, volume_m3::text
               """,
               [item.uuid]
             )

    assert Decimal.equal?(Decimal.new(area), Decimal.new("3.125"))

    assert {:ok, %{rows: [[nil, nil]]}} =
             Repo.query(
               """
               UPDATE phoenix_kit_cat_items SET width_mm = NULL
               WHERE uuid = $1::text::uuid RETURNING area_m2::text, volume_m3::text
               """,
               [item.uuid]
             )
  end

  test "the dimensions are stored as given: a length below the width is fine", %{item: item} do
    assert {:ok, %{rows: [[area, _volume]]}} = set_dimensions(item, "1250", "2500", "18")
    assert Decimal.equal?(Decimal.new(area), Decimal.new("3.125"))

    assert %{rows: [["1250.000", "2500.000"]]} =
             Repo.query!(
               "SELECT length_mm::text, width_mm::text FROM phoenix_kit_cat_items WHERE uuid = $1::text::uuid",
               [item.uuid]
             )
  end

  test "the generated columns cannot be written", %{item: item} do
    assert {:error, %Postgrex.Error{postgres: %{code: :generated_always}}} =
             Repo.query(
               "UPDATE phoenix_kit_cat_items SET volume_m3 = 1 WHERE uuid = $1::text::uuid",
               [item.uuid]
             )
  end

  for column <- ~w(length_mm width_mm thickness_mm pack_size), value <- ["0", "-1"] do
    test "items.#{column} refuses #{value}", %{item: item} do
      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               Repo.query(
                 "UPDATE phoenix_kit_cat_items SET #{unquote(column)} = $2::text::numeric WHERE uuid = $1::text::uuid",
                 [item.uuid, unquote(value)]
               )

      assert constraint == "phoenix_kit_cat_items_#{unquote(column)}_check"
    end
  end

  test "supplier info: pack_size above zero only, cost_unit free text", %{item: item} do
    insert = fn pack_size ->
      Repo.query(
        """
        INSERT INTO phoenix_kit_cat_item_supplier_info
          (item_uuid, supplier_uuid, supplier_source, cost_unit, pack_size, inserted_at, updated_at)
        VALUES ($1::text::uuid, uuid_generate_v7(), 'local', 'm3', $2::text::numeric, now(), now())
        """,
        [item.uuid, pack_size]
      )
    end

    assert {:ok, _} = insert.("35")

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "phoenix_kit_cat_item_supplier_info_pack_size_check"}
            }} = insert.("0")
  end
end
