defmodule PhoenixKitCatalogue.Web.CatalogueDetailBulkKindsTest do
  @moduledoc """
  The detail page flashes bulk-change rows red as "leaving" for every kind it
  did not know. `:created` and `:updated` (the shop API's batch writes) are not
  departures: they must not red-flash; a created row flashes green on arrival.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  setup do
    cat = fixture_catalogue(%{name: "Bulk Kinds"})
    item = fixture_item(%{name: "Listed", catalogue_uuid: cat.uuid})
    %{catalogue: cat, item: item}
  end

  defp mount_detail(conn, cat), do: live(conn, "/en/admin/catalogues/#{cat.uuid}")

  test ":updated does not red-flash the rows", %{conn: conn, catalogue: cat, item: item} do
    {:ok, view, _html} = mount_detail(conn, cat)
    other = spawn(fn -> :ok end)

    send(view.pid, {:catalogue_bulk_change, cat.uuid, :updated, [item.uuid], other})
    _ = render(view)

    refute_push_event(view, "sortable:flash", %{status: "error"})
    assert Process.alive?(view.pid)
  end

  test ":created does not red-flash either", %{conn: conn, catalogue: cat, item: item} do
    {:ok, view, _html} = mount_detail(conn, cat)
    other = spawn(fn -> :ok end)

    send(view.pid, {:catalogue_bulk_change, cat.uuid, :created, [item.uuid], other})
    _ = render(view)

    refute_push_event(view, "sortable:flash", %{status: "error"})
  end

  test "the old kinds still red-flash", %{conn: conn, catalogue: cat, item: item} do
    {:ok, view, _html} = mount_detail(conn, cat)
    other = spawn(fn -> :ok end)

    send(view.pid, {:catalogue_bulk_change, cat.uuid, :trashed, [item.uuid], other})
    _ = render(view)

    assert_push_event(view, "sortable:flash", %{status: "error", uuid: uuid})
    assert uuid == item.uuid
  end

  test "the apply step flashes a created row green and an updated one not at all",
       %{conn: conn, catalogue: cat, item: item} do
    {:ok, view, _html} = mount_detail(conn, cat)

    send(view.pid, {:bulk_change_apply, :updated, [item.uuid]})
    _ = render(view)
    refute_push_event(view, "sortable:flash", %{status: "ok"})

    send(view.pid, {:bulk_change_apply, :created, [item.uuid]})
    _ = render(view)
    assert_push_event(view, "sortable:flash", %{status: "ok", uuid: uuid})
    assert uuid == item.uuid
  end
end
