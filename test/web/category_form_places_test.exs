defmodule PhoenixKitCatalogue.Web.CategoryFormPlacesTest do
  @moduledoc """
  Where the category form puts a category, and what it shows as its
  place: a parent in the URL is used only when the tree offers it, a
  catalogue gone from under an open form does not crash it, and a move
  made elsewhere moves the Move picker's "current" with it.
  """
  use PhoenixKitCatalogue.LiveCase

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.Test.Repo
  alias PhoenixKitWeb.Components.TreePicker

  @base "/en/admin/catalogue"

  defp form_selector, do: ~s|form[action="#"][phx-submit=save]|

  test "a parent in the URL from another catalogue is not used", %{conn: conn} do
    [here, there] = [fixture_catalogue(), fixture_catalogue()]
    foreign = fixture_category(there, %{name: "Foreign"})

    {:ok, view, _html} =
      live(conn, "#{@base}/#{here.uuid}/categories/new?parent_uuid=#{foreign.uuid}")

    view
    |> form(form_selector(), %{"category" => %{"name" => "Lands on top"}})
    |> render_submit()

    assert [%{parent_uuid: nil}] =
             Enum.filter(
               Catalogue.list_categories_metadata_for_catalogue(here.uuid),
               &(&1.name == "Lands on top")
             )
  end

  test "a refused parent says so under the picker", %{conn: conn} do
    catalogue = fixture_catalogue()
    parent = fixture_category(catalogue, %{name: "Going"})

    {:ok, view, _html} =
      live(conn, "#{@base}/#{catalogue.uuid}/categories/new?parent_uuid=#{parent.uuid}")

    # Trashed without a broadcast reaching the form: the pick is stale.
    Repo.update_all(
      from(c in PhoenixKitCatalogue.Schemas.Category, where: c.uuid == ^parent.uuid),
      set: [status: "deleted"]
    )

    html =
      view
      |> form(form_selector(), %{"category" => %{"name" => "Orphan"}})
      |> render_submit()

    assert html =~ "The chosen parent is no longer available. Pick another place."
  end

  test "an open New form survives its catalogue being deleted", %{conn: conn} do
    catalogue = fixture_catalogue()
    {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}/categories/new")

    Repo.delete_all(from(c in CatalogueSchema, where: c.uuid == ^catalogue.uuid))
    send(view.pid, {:catalogue_data_changed, :catalogue, catalogue.uuid, nil})

    assert render(view) =~ "New category"
  end

  test "a move made elsewhere moves the picker's current place", %{conn: conn} do
    catalogue = fixture_catalogue()
    category = fixture_category(catalogue, %{name: "Mover"})
    new_parent = fixture_category(catalogue, %{name: "New home"})

    {:ok, view, _html} = live(conn, "#{@base}/categories/#{category.uuid}/edit")

    {:ok, _} = Catalogue.move_category_under(category, new_parent.uuid)
    _ = render(view)

    # Picking where it now is stages nothing.
    send(view.pid, {TreePicker, "category-move-picker", "category:" <> new_parent.uuid})
    assert has_element?(view, "#category-move-button[disabled]")
  end

  test "a move from the form is logged with its actor", %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue()
    category = fixture_category(catalogue, %{name: "Moved"})
    parent = fixture_category(catalogue, %{name: "Under"})

    {:ok, view, _html} =
      conn |> with_scope(scope) |> live("#{@base}/categories/#{category.uuid}/edit")

    send(view.pid, {TreePicker, "category-move-picker", "category:" <> parent.uuid})
    view |> element("#category-move-button") |> render_click()

    assert Catalogue.get_category(category.uuid).parent_uuid == parent.uuid

    assert_activity_logged("category.moved",
      actor_uuid: scope.user.uuid,
      resource_uuid: category.uuid
    )
  end
end
