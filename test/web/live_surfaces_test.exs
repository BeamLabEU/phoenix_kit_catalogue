defmodule PhoenixKitCatalogue.Web.LiveSurfacesTest do
  @moduledoc """
  Cross-session liveness of the admin surfaces (2026-08 "as live as we
  can" batch): a mutation performed by ANOTHER process (the test process
  stands in for a second browser tab) must show up on an already-open
  page without a reload. Each test fails without its fix.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  @base "/en/admin/catalogue"

  # A live, non-image document row in `folder_uuid` — what the paperclip
  # counts. Inserted raw like attachments_lv_test does (no bucket needed).
  defp insert_document!(folder_uuid, %{user: %{uuid: user_uuid}}, name \\ "spec.pdf") do
    uuid = Ecto.UUID.generate()

    {:ok, _} =
      TestRepo.query("""
      INSERT INTO phoenix_kit_files
        (uuid, file_name, original_file_name, mime_type, file_type, ext,
         file_checksum, user_file_checksum, size, file_path, folder_uuid, user_uuid,
         status, metadata, inserted_at, updated_at)
      VALUES
        ('#{uuid}', '#{name}', '#{name}', 'application/pdf', 'document', 'pdf',
         '#{uuid}', '#{uuid}', 100, 'k', '#{folder_uuid}', '#{user_uuid}',
         'active', '{}'::jsonb, NOW(), NOW())
      """)

    uuid
  end

  defp folder!(name) do
    {:ok, folder} = Storage.create_folder(%{name: name})
    folder
  end

  defp files_state_uuids(view) do
    :sys.get_state(view.pid).socket.assigns.files_state.files |> Enum.map(& &1.uuid)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Async work (start_async searches) lands a tick later — poll instead of
  # sleeping a fixed amount.
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp search_uuids(view) do
    _ = render(view)
    (assigns(view).search_results || []) |> Enum.map(& &1.uuid)
  end

  defp index_row(view, uuid) do
    :sys.get_state(view.pid).socket.assigns.catalogue_rows
    |> Enum.find(&(&1.uuid == uuid))
  end

  defp detail_item_uuids(view) do
    :sys.get_state(view.pid).socket.assigns.items |> Enum.map(& &1.uuid)
  end

  describe "F3 — attachment writes announce the owning resource" do
    test "removing a file from an item broadcasts :item with its catalogue", %{
      conn: conn,
      scope: scope
    } do
      folder = folder!("catalogue-item-f3")
      cat = fixture_catalogue()

      item =
        fixture_item(%{
          name: "Doc holder",
          catalogue_uuid: cat.uuid,
          data: %{"files_folder_uuid" => folder.uuid}
        })

      file_uuid = insert_document!(folder.uuid, scope)
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")
      assert file_uuid in files_state_uuids(view)

      PubSub.subscribe()
      render_click(view, "remove_file", %{"uuid" => file_uuid})

      assert_receive {:catalogue_data_changed, :item, uuid, parent}
      assert uuid == item.uuid
      assert parent == cat.uuid
      refute file_uuid in files_state_uuids(view)
    end

    test "removing a file from a catalogue broadcasts :catalogue", %{conn: conn, scope: scope} do
      folder = folder!("catalogue-f3")
      cat = fixture_catalogue(%{data: %{"files_folder_uuid" => folder.uuid}})
      file_uuid = insert_document!(folder.uuid, scope)
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}/edit")

      PubSub.subscribe()
      render_click(view, "remove_file", %{"uuid" => file_uuid})

      assert_receive {:catalogue_data_changed, :catalogue, uuid, parent}
      assert uuid == cat.uuid
      assert parent == cat.uuid
    end

    test "a miss (unknown file) writes nothing and stays silent", %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}/edit")

      PubSub.subscribe()
      render_click(view, "remove_file", %{"uuid" => Ecto.UUID.generate()})
      refute_receive {:catalogue_data_changed, _, _, _}
    end

    test "the catalogues index paperclip count follows the removal", %{conn: conn, scope: scope} do
      folder = folder!("catalogue-f3-index")
      cat = fixture_catalogue(%{data: %{"files_folder_uuid" => folder.uuid}})
      file_uuid = insert_document!(folder.uuid, scope)

      {:ok, index, _} = live(conn, @base)
      assert :sys.get_state(index.pid).socket.assigns.catalogue_file_counts[cat.uuid] == 1

      {:ok, form, _} = live(conn, "#{@base}/#{cat.uuid}/edit")
      render_click(form, "remove_file", %{"uuid" => file_uuid})

      _ = render(index)

      refute Map.has_key?(
               :sys.get_state(index.pid).socket.assigns.catalogue_file_counts,
               cat.uuid
             )
    end
  end

  describe "F4 — closing the media selector re-reads the folder" do
    test "a file that landed while the modal was open shows up on close", %{
      conn: conn,
      scope: scope
    } do
      folder = folder!("catalogue-f4")
      cat = fixture_catalogue(%{data: %{"files_folder_uuid" => folder.uuid}})
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}/edit")
      assert files_state_uuids(view) == []

      render_click(view, "open_featured_image_picker", %{})
      # The core modal stored an upload straight into the folder…
      file_uuid = insert_document!(folder.uuid, scope)
      # …and the user closed it without confirming.
      PubSub.subscribe()
      send(view.pid, {:media_selector_closed})
      _ = render(view)

      assert files_state_uuids(view) == [file_uuid]
      refute :sys.get_state(view.pid).socket.assigns.show_media_selector
      # The folder changed under this resource: other surfaces hear it.
      assert_receive {:catalogue_data_changed, :catalogue, uuid, _}
      assert uuid == cat.uuid
    end

    test "closing with nothing new is silent", %{conn: conn} do
      folder = folder!("catalogue-f4-quiet")
      cat = fixture_catalogue(%{data: %{"files_folder_uuid" => folder.uuid}})
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}/edit")

      PubSub.subscribe()
      render_click(view, "close_media_selector", %{})
      refute_receive {:catalogue_data_changed, _, _, _}
    end
  end

  describe "F2 — detail indicators clear when the last file / the group goes away" do
    test "clearing an item's attribute group drops the swatch", %{conn: conn} do
      cat = fixture_catalogue()
      item = fixture_item(%{name: "Swatched", catalogue_uuid: cat.uuid})
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Doors"})
      {:ok, :assigned} = Catalogue.set_item_attribute_group(item, group.uuid)

      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")
      assert Map.has_key?(assigns(view).attribute_map, item.uuid)
      assert render(view) =~ "Has attribute group"

      {:ok, :cleared} = Catalogue.set_item_attribute_group(item, nil)
      refute render(view) =~ "Has attribute group"
      refute Map.has_key?(assigns(view).attribute_map, item.uuid)
    end

    test "removing an item's last document drops the paperclip count",
         %{conn: conn, scope: scope} do
      folder = folder!("catalogue-item-f2")
      cat = fixture_catalogue()

      item =
        fixture_item(%{
          name: "Clipped",
          catalogue_uuid: cat.uuid,
          data: %{"files_folder_uuid" => folder.uuid}
        })

      file_uuid = insert_document!(folder.uuid, scope)
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")
      assert assigns(view).file_counts[item.uuid] == 1

      # The other tab trashed the file (what Attachments.trash_file does)
      # and announced the item.
      {:ok, _} =
        TestRepo.query("UPDATE phoenix_kit_files SET status = 'trashed' WHERE uuid = $1", [
          Ecto.UUID.dump!(file_uuid)
        ])

      PubSub.broadcast(:item, item.uuid, cat.uuid)
      _ = render(view)
      assert Map.get(assigns(view).file_counts, item.uuid, 0) == 0
    end
  end

  describe "F7 — an active search follows writes and tab switches" do
    setup do
      cat = fixture_catalogue()
      alpha = fixture_item(%{name: "Alpha Bolt", catalogue_uuid: cat.uuid})
      beta = fixture_item(%{name: "Beta Nut", catalogue_uuid: cat.uuid})
      %{catalogue: cat, alpha: alpha, beta: beta}
    end

    test "a rename elsewhere re-runs the search", %{conn: conn, catalogue: cat, alpha: a, beta: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?q=Alpha")
      eventually(fn -> search_uuids(view) == [a.uuid] end)

      {:ok, _} = Catalogue.update_item(b, %{name: "Alpha Nut"})
      eventually(fn -> Enum.sort(search_uuids(view)) == Enum.sort([a.uuid, b.uuid]) end)
    end

    test "switching the status tab clears the search grid", %{
      conn: conn,
      catalogue: cat,
      alpha: a
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?q=Alpha")
      eventually(fn -> search_uuids(view) == [a.uuid] end)

      render_click(view, "switch_view", %{"mode" => "deleted"})
      _ = render(view)

      # (The empty Deleted tab auto-flips back to Active, where "Alpha
      # Bolt" is a normal level row again — the search grid is what's gone.)
      assert assigns(view).search_results == nil
      assert assigns(view).search_query == ""
      refute has_element?(view, "form[phx-submit=search] input[value='Alpha']")
    end
  end

  describe "F6 — the attribute-group editor follows child writes from other processes" do
    setup do
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Idea doors"})
      {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})
      %{group: group, attribute: attribute}
    end

    test "a translation job's write shows up without a timer",
         %{conn: conn, group: group, attribute: attribute} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      {:ok, _} = AITranslatable.put_translation(attribute, "et", %{"name" => "Värv"}, [])
      _ = render(view)

      [loaded] = :sys.get_state(view.pid).socket.assigns.group.attributes
      assert loaded.data["et"]["_name"] == "Värv"
    end

    test "a colleague adding an attribute appears in the list", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")
      refute render(view) =~ "Material"

      {:ok, _} = Catalogue.create_attribute(group, %{"name" => "Material"})
      assert render(view) =~ "Material"
    end

    test "another group's events are ignored", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")
      {:ok, other} = Catalogue.create_attribute_group(%{name: "Other"})
      {:ok, _} = Catalogue.create_attribute(other, %{"name" => "Finish"})

      refute render(view) =~ "Finish"
    end

    test "the group being deleted elsewhere bounces to the list", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      {:ok, _} = Catalogue.delete_attribute_group(group)
      assert_redirect(view, "#{@base}/attributes")
    end
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
