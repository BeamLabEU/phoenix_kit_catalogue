defmodule PhoenixKitCatalogue.Web.TableQueryTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.TableQuery, as: Q

  defp rows do
    [
      %{
        name: "Beta",
        status: "active",
        item_count: 3,
        folder_uuid: "f1",
        folder_name: "Kitchen",
        updated_at: ~U[2026-01-02 00:00:00Z],
        position: 1
      },
      %{
        name: "alpha",
        status: "archived",
        item_count: 9,
        folder_uuid: nil,
        folder_name: nil,
        updated_at: ~U[2026-01-01 00:00:00Z],
        position: 0
      }
    ]
  end

  test "search is case-insensitive substring on name" do
    assert Enum.map(Q.search(rows(), "al"), & &1.name) == ["alpha"]
    assert Q.search(rows(), "") == rows()
  end

  test "filter by status; 'all'/nil are no-ops" do
    assert Enum.map(Q.filter(rows(), :catalogues, %{"status" => "active"}), & &1.name) == ["Beta"]
    assert Q.filter(rows(), :catalogues, %{"status" => "all"}) == rows()
  end

  test "filter by folder uuid" do
    assert Enum.map(Q.filter(rows(), :catalogues, %{"folder" => "f1"}), & &1.name) == ["Beta"]
  end

  test "sort by name is case-insensitive; dir respected" do
    assert Enum.map(Q.sort(rows(), :catalogues, "name", :asc), & &1.name) == ["alpha", "Beta"]
    assert Enum.map(Q.sort(rows(), :catalogues, "name", :desc), & &1.name) == ["Beta", "alpha"]
  end

  test "sort by position (manual order)" do
    assert Enum.map(Q.sort(rows(), :catalogues, "position", :asc), & &1.name) == [
             "alpha",
             "Beta"
           ]
  end

  test "enum_options for folder skips unfiled and dedups" do
    assert Q.enum_options(rows(), :catalogues, "folder") == [{"f1", "Kitchen"}]
  end

  # Regression: `to_string(nil) == ""`, which `filter/2` already reserves to
  # mean "no filter set" — so the unfiled sentinel must be a distinct value,
  # not the row's stringified nil folder_uuid.
  test "filter by the unfiled sentinel matches only rows with a nil folder_uuid" do
    assert Enum.map(
             Q.filter(rows(), :catalogues, %{"folder" => Q.unfiled_folder_value()}),
             & &1.name
           ) ==
             ["alpha"]
  end
end
