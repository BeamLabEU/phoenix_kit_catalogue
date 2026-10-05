defmodule PhoenixKitCatalogue.Web.LegacyPathTest do
  @moduledoc """
  The module's pages moved from `/admin/catalogue` to `/admin/catalogues`.
  What still points at the old address — bookmarks, sent mail, the activity
  log, sibling modules released before the change — has to keep landing.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.LegacyPathController, as: Legacy
  alias PhoenixKitCatalogue.Web.Routes

  describe "target/2" do
    test "the landing page, with and without a prefix and a locale" do
      assert Legacy.target("/admin/catalogue") == "/admin/catalogues"
      assert Legacy.target("/phoenix_kit/admin/catalogue") == "/phoenix_kit/admin/catalogues"

      assert Legacy.target("/phoenix_kit/et/admin/catalogue") ==
               "/phoenix_kit/et/admin/catalogues"
    end

    test "everything after the segment carries over" do
      assert Legacy.target("/en/admin/catalogue/items/abc/edit") ==
               "/en/admin/catalogues/items/abc/edit"

      assert Legacy.target("/admin/catalogue/abc", "category=def&q=oak") ==
               "/admin/catalogues/abc?category=def&q=oak"
    end

    test "only the whole segment moves, and only once" do
      assert Legacy.target("/admin/catalogues/abc") == "/admin/catalogues/abc"
      assert Legacy.target("/admin/catalogue-old") == "/admin/catalogue-old"

      assert Legacy.target("/admin/catalogue/x/admin/catalogue") ==
               "/admin/catalogues/x/admin/catalogue"
    end
  end

  test "both route sets carry the old address, as the landing page and as a prefix" do
    for routes <- [Routes.admin_routes(), Routes.admin_locale_routes()] do
      source = Macro.to_string(routes)

      assert source =~ ~s("/admin/catalogue",)
      assert source =~ ~s("/admin/catalogue/*rest")
      assert source =~ "LegacyPathController"
    end
  end

  test "the module's own paths are under the plural address" do
    assert Paths.index() =~ ~r{/admin/catalogues$}
    refute Paths.index() =~ ~r{/admin/catalogue(/|$)}
  end
end
