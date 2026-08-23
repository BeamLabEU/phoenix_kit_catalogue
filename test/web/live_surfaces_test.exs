defmodule PhoenixKitCatalogue.Web.LiveSurfacesTest do
  @moduledoc """
  Cross-session liveness of the admin surfaces (2026-08 "as live as we
  can" batch): a mutation performed by ANOTHER process (the test process
  stands in for a second browser tab) must show up on an already-open
  page without a reload. Each test fails without its fix.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub

  @base "/en/admin/catalogue"

  defp index_row(view, uuid) do
    :sys.get_state(view.pid).socket.assigns.catalogue_rows
    |> Enum.find(&(&1.uuid == uuid))
  end

  defp detail_item_uuids(view) do
    :sys.get_state(view.pid).socket.assigns.items |> Enum.map(& &1.uuid)
  end

  describe "F1 — catalogues index Items column follows bulk item ops from another tab" do
    setup do
      cat = fixture_catalogue(%{name: "Bulk Cat"})
      a = fixture_item(%{name: "A", catalogue_uuid: cat.uuid})
      b = fixture_item(%{name: "B", catalogue_uuid: cat.uuid})
      %{catalogue: cat, a: a, b: b}
    end

    test "bulk trash / restore / permanent delete", %{conn: conn, catalogue: cat, a: a, b: b} do
      {:ok, view, _html} = live(conn, @base)
      assert index_row(view, cat.uuid).item_count == 2

      {2, nil} = Catalogue.bulk_trash_items([a.uuid, b.uuid], [])
      _ = render(view)
      assert index_row(view, cat.uuid).item_count == 0

      {1, nil} = Catalogue.bulk_restore_items([a.uuid], [])
      _ = render(view)
      assert index_row(view, cat.uuid).item_count == 1

      {1, nil} = Catalogue.bulk_permanently_delete_items([b.uuid], [])
      _ = render(view)
      assert index_row(view, cat.uuid).item_count == 1
    end

    test "detail page of the same catalogue drops bulk-trashed items",
         %{conn: conn, catalogue: cat, a: a, b: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")
      assert Enum.sort(detail_item_uuids(view)) == Enum.sort([a.uuid, b.uuid])

      {1, nil} = Catalogue.bulk_trash_items([a.uuid], [])
      _ = render(view)
      assert detail_item_uuids(view) == [b.uuid]
    end

    test "a pending cross-tab bulk flash holds the reload until the apply step",
         %{conn: conn, catalogue: cat, a: a, b: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

      # The other tab: mutate muted, announce the flash, then the batch
      # event — the order the detail LV's bulk handlers use.
      {1, nil} = Catalogue.bulk_trash_items([a.uuid], broadcast: false)
      other = spawn(fn -> :ok end)
      send(view.pid, {:catalogue_bulk_change, cat.uuid, :trashed, [a.uuid], other})
      PubSub.broadcast(:item, nil, cat.uuid)

      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.bulk_change_pending
      # Still on screen: the red "leaving" flash gets to play first.
      assert a.uuid in detail_item_uuids(view)

      Process.sleep(900)
      _ = render(view)
      refute :sys.get_state(view.pid).socket.assigns.bulk_change_pending
      assert detail_item_uuids(view) == [b.uuid]
    end
  end
end
