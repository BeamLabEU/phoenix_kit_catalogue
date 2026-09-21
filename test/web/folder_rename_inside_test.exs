defmodule PhoenixKitCatalogue.Web.FolderRenameInsideTest do
  @moduledoc """
  A folder can be renamed from inside it (boss via Max, 2026-09-21: "you
  can't rename a folder from inside a folder — you have to go back out and
  use the three dots"). The folder you stand in has no row of its own on
  screen, so the location row carries the rename.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    {:ok, folder} = Catalogue.create_folder(%{name: "Old name"})
    %{conn: with_scope(conn, scope), folder: folder}
  end

  defp inside(conn, folder) do
    {:ok, view, _html} = live(conn, @base)
    render_click(view, "navigate_folder", %{"uuid" => folder.uuid})
    view
  end

  test "the pencil turns the name into a field, and Enter saves", %{conn: conn, folder: folder} do
    view = inside(conn, folder)

    view |> element("#location-rename-button") |> render_click()
    assert has_element?(view, "#location-rename-#{folder.uuid} input[name=name]")

    view
    |> form("#location-rename-#{folder.uuid}", %{"name" => "New name"})
    |> render_submit()

    assert Catalogue.get_folder(folder.uuid).name == "New name"
    # Still inside the folder, showing the new name, field closed.
    assert has_element?(view, "#location-rename-button")
    assert render(view) =~ "New name"
  end

  test "clicking away saves too; a blank name keeps the old one", %{conn: conn, folder: folder} do
    view = inside(conn, folder)
    view |> element("#location-rename-button") |> render_click()

    view
    |> element("#location-rename-#{folder.uuid} input")
    |> render_blur(%{"value" => "   "})

    assert Catalogue.get_folder(folder.uuid).name == "Old name"

    view |> element("#location-rename-button") |> render_click()

    view
    |> element("#location-rename-#{folder.uuid} input")
    |> render_blur(%{"value" => "Blurred name"})

    assert Catalogue.get_folder(folder.uuid).name == "Blurred name"
  end

  test "at the top level there is no location row to rename", %{conn: conn} do
    {:ok, view, _html} = live(conn, @base)
    refute has_element?(view, "#location-rename-button")
  end
end
