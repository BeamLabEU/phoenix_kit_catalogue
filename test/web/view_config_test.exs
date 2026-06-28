defmodule PhoenixKitCatalogue.Web.ViewConfigTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.ViewConfig, as: VC

  test "defaults shape" do
    assert %{
             columns: ["name", "folder", "items", "status", "updated"],
             sort_by: "name",
             sort_dir: :asc,
             filters: %{},
             view: "table"
           } = VC.defaults(:catalogues)
  end

  test "normalize falls back on empty/invalid, keeps valid" do
    assert VC.normalize(:catalogues, %{}) == VC.defaults(:catalogues)

    got =
      VC.normalize(:catalogues, %{
        "columns" => ["items", "bogus"],
        "sort_dir" => "desc",
        "view" => "card"
      })

    assert got.columns == ["items"]
    assert got.sort_dir == :desc
    assert got.view == "card"
  end

  test "load reads from a user struct's custom_fields" do
    user = %{custom_fields: %{"catalogue_view_configs" => %{"suppliers" => %{"view" => "card"}}}}
    assert VC.load(user, :suppliers).view == "card"
    assert VC.load(%{custom_fields: nil}, :suppliers) == VC.defaults(:suppliers)
  end
end
