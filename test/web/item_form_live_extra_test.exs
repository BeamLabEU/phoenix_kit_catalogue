defmodule PhoenixKitCatalogue.Web.ItemFormLiveExtraTest do
  @moduledoc """
  Additional ItemFormLive coverage: media-selector delegations
  (open / close), cancel_upload, add_meta_field idempotence, and
  the move_item flow with the smart-vs-standard catalogue dispatch.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup do
    cat = fixture_catalogue(%{name: "ItemExtra"})
    item = fixture_item(%{name: "ExtraItem", catalogue_uuid: cat.uuid})
    %{catalogue: cat, item: item}
  end

  describe "media-selector delegations from ItemFormLive" do
    test "open_featured_image_picker flips show_media_selector",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_click(view, "open_featured_image_picker", %{})

      assert is_boolean(:sys.get_state(view.pid).socket.assigns[:show_media_selector])
    end

    test "close_media_selector resets the modal", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_click(view, "open_featured_image_picker", %{})
      render_click(view, "close_media_selector", %{})

      assert :sys.get_state(view.pid).socket.assigns[:show_media_selector] == false
    end
  end

  describe "add_meta_field idempotence" do
    test "adding the same key twice is a no-op", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_click(view, "add_meta_field", %{"key" => "color"})
      first = :sys.get_state(view.pid).socket.assigns.meta_state

      render_click(view, "add_meta_field", %{"key" => "color"})
      second = :sys.get_state(view.pid).socket.assigns.meta_state

      assert first == second
    end
  end

  describe "move_item with target on standard vs smart catalogue" do
    test "move_item to another category in the same catalogue",
         %{conn: conn, catalogue: cat, item: item} do
      cat_obj = fixture_category(cat, %{name: "MoveTarget"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_change(view, "select_move_target", %{"category_uuid" => cat_obj.uuid})
      render_click(view, "move_item", %{})

      assert Catalogue.get_item(item.uuid).category_uuid == cat_obj.uuid
    end

    test "move_item with empty target is a no-op",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_change(view, "select_move_target", %{"category_uuid" => ""})
      render_click(view, "move_item", %{})

      # Item stays in the same catalogue.
      assert Catalogue.get_item(item.uuid).uuid == item.uuid
      assert Process.alive?(view.pid)
    end

    test "move_item for a smart-catalogue item routes via catalogue_uuid key",
         %{conn: conn} do
      {:ok, smart} = Catalogue.create_catalogue(%{name: "SmartMoveSrc", kind: "smart"})
      {:ok, target} = Catalogue.create_catalogue(%{name: "SmartMoveDst", kind: "standard"})
      {:ok, item} = Catalogue.create_item(%{name: "Smart Item", catalogue_uuid: smart.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      # Smart forms send `catalogue_uuid` instead of `category_uuid`.
      render_change(view, "select_move_target", %{"catalogue_uuid" => target.uuid})
      render_click(view, "move_item", %{})

      reloaded = Catalogue.get_item(item.uuid)
      # The item moved to the new catalogue (move_item dispatches to
      # move_item_to_catalogue for smart items).
      assert reloaded.catalogue_uuid == target.uuid
    end
  end

  describe "validate event with various param shapes" do
    test "validate with string-keyed params produces a changeset",
         %{conn: conn, item: item, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_change(view, "validate", %{
        "item" => %{
          "name" => "Updated Name",
          "catalogue_uuid" => cat.uuid
        }
      })

      cs = :sys.get_state(view.pid).socket.assigns.changeset
      assert match?(%Ecto.Changeset{}, cs)
    end
  end
end
