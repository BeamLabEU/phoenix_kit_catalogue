defmodule PhoenixKitCatalogue.Web.TableConfigTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.TableConfig, as: TC

  test "catalogues defaults are the visible managed+name set, in order" do
    assert TC.default_columns(:catalogues) == ["name", "folder", "items", "status", "updated"]
  end

  test "name is always present but not managed (never hidden via modal)" do
    refute Enum.any?(TC.managed_columns(:catalogues), &(&1.id == "name"))
    assert TC.column_map(:catalogues)["name"].managed? == false
  end

  test "position is a sortable, unmanaged, non-default pseudo column (manual order)" do
    col = TC.column_map(:catalogues)["position"]
    assert col.sortable?
    refute col.managed?
    refute col.default?
    # Never listed among managed columns (can't be toggled via the Columns
    # modal) or default columns (never a real grid column) — it only ever
    # surfaces as a sort option.
    refute Enum.any?(TC.managed_columns(:catalogues), &(&1.id == "position"))
    refute "position" in TC.default_columns(:catalogues)
  end

  test "position's sort_key ties break on case-insensitive name" do
    # Mirrors Catalogue.list_catalogues/1's `order_by: [asc: :position, asc:
    # :name]` — every legacy catalogue defaults to `position: 0`, so without
    # this tie-break the admin list and the printed-document order it's
    # meant to match can disagree on every tied row.
    sort_key = TC.column_map(:catalogues)["position"].sort_key

    rows = [
      %{position: 0, name: "Zeta"},
      %{position: 0, name: "alpha"},
      %{position: 0, name: "Mid"}
    ]

    assert rows |> Enum.sort_by(sort_key) |> Enum.map(& &1.name) == ["alpha", "Mid", "Zeta"]
  end

  test "validate_columns drops unknown + non-managed ids and dedups" do
    assert TC.validate_columns(:catalogues, ["items", "items", "bogus", "name"]) == ["items"]
  end

  test "sortable_visible keeps only sortable, in given order" do
    ids = ["status", "name", "markup"]
    assert Enum.map(TC.sortable_visible(:catalogues, ids), & &1.id) == ids
  end

  test "suppliers/manufacturers share the column shape" do
    assert TC.default_columns(:suppliers) == ["name", "website", "status"]
    assert TC.default_columns(:manufacturers) == ["name", "website", "status"]
  end
end
