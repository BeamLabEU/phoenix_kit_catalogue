defmodule PhoenixKitCatalogue.MediaReorganizerTest do
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.MediaReorganizer
  alias PhoenixKitCatalogue.Schemas.{Category, Item, Pdf}

  defmodule Hook do
    def parent(:item, _actor, %Item{}), do: {:ok, Process.get(:target_folder)}
    def parent(:category, _actor, %Category{}), do: {:ok, Process.get(:target_folder)}
    def parent(:catalogue, _actor, %{}), do: {:ok, Process.get(:target_folder)}
    def parent(_, _, _), do: nil
    def name(_resource, _actor), do: {:ok, Process.get(:target_name) || nil}
  end

  defmodule PdfHook do
    def parent(:pdf, _actor, :pdf), do: {:ok, Process.get(:pdf_folder)}
    def parent(_, _, _), do: nil
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_catalogue, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_catalogue, :attachments_folder_name)
    end)

    {:ok, user_uuid: fixture_user_uuid()}
  end

  # A minimal `phoenix_kit_users` row so `Storage.create_file/1`'s
  # `user_uuid` FK has something to reference — same pattern as
  # `LiveCase.build_admin_scope/0`.
  defp fixture_user_uuid do
    uuid = UUIDv7.generate()
    email = "reorg-test-#{System.unique_integer([:positive])}@example.com"

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(uuid),
        email,
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    uuid
  end

  defp new_catalogue(attrs \\ %{}) do
    {:ok, catalogue} = Catalogue.create_catalogue(Map.merge(%{name: "Cat"}, attrs))
    catalogue
  end

  defp new_item(catalogue, attrs \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Widget", catalogue_uuid: catalogue.uuid}, attrs))

    item
  end

  test "no hooks configured, legacy folder at root, pointer set → nothing planned" do
    catalogue = new_catalogue()
    item = new_item(catalogue)

    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :item and &1.label == item.name))
  end

  test "hooks configured, legacy folder at root, pointer set → one move action" do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})
    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item))

    assert action.source == "catalogue"
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == "Nice"
    assert action.on_conflict == :suffix
    assert action.counts == {0, 0}
    assert action.label == item.name
    # pointer already correct → no back-fill needed
    assert is_nil(action.after_move)
  end

  test "counts include a trashed file — the engine re-measures the same way at apply time", %{
    user_uuid: user_uuid
  } do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})
    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

    {:ok, _trashed_file} =
      Storage.create_file(%{
        original_file_name: "old.pdf",
        file_name: "old.pdf",
        mime_type: "application/pdf",
        file_type: "document",
        ext: "pdf",
        file_checksum: "checksum-trashed",
        user_file_checksum: "user-checksum-trashed",
        size: 10,
        status: "trashed",
        folder_uuid: folder.uuid,
        user_uuid: user_uuid
      })

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item))

    assert action.counts == {1, 0}
  end

  test "pointer missing (folder found by legacy name) → after_move back-fills it" do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})
    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item))

    assert action.folder.uuid == folder.uuid
    assert is_function(action.after_move, 0)

    assert :ok = action.after_move.()

    reloaded = Catalogue.get_item!(item.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
  end

  test "pointer points at a trashed folder while a live legacy folder exists at root → the live one is used" do
    catalogue = new_catalogue()
    item = new_item(catalogue)

    {:ok, trashed} = Storage.create_folder(%{name: "old-pointer-target"})
    {:ok, trashed} = Storage.trash_folder(trashed)
    {:ok, live} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => trashed.uuid}})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))

    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  test "categories and catalogues get actions too" do
    catalogue = new_catalogue(%{name: "Root cat"})
    {:ok, category} = Catalogue.create_category(%{name: "Cards", catalogue_uuid: catalogue.uuid})

    {:ok, cat_folder} = Storage.create_folder(%{name: "catalogue-#{catalogue.uuid}"})

    {:ok, catalogue} =
      Catalogue.update_catalogue(catalogue, %{data: %{"files_folder_uuid" => cat_folder.uuid}})

    {:ok, cat_folder2} = Storage.create_folder(%{name: "catalogue-category-#{category.uuid}"})

    {:ok, category} =
      Catalogue.update_category(category, %{data: %{"files_folder_uuid" => cat_folder2.uuid}})

    Process.put(:target_folder, cat_folder.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    assert Enum.any?(actions, &(&1.kind == :catalogue and &1.label == catalogue.name))
    assert Enum.any?(actions, &(&1.kind == :category and &1.label == category.name))
  end

  describe "pending folders" do
    test "empty pending folder older than pending_days → op: :trash" do
      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :trash
    end

    test "non-empty pending folder → op: :report with the file name in the reason", %{
      user_uuid: user_uuid
    } do
      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "leftover.pdf",
          file_name: "leftover.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-1",
          user_file_checksum: "user-checksum-1",
          size: 10,
          status: "active",
          folder_uuid: folder.uuid,
          user_uuid: user_uuid
        })

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :report
      assert action.reason =~ "leftover.pdf"
    end

    test "pending folder younger than pending_days → no action" do
      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end
  end

  describe "orphan folders" do
    test "legacy folder with no matching record → orphan report with counts", %{
      user_uuid: user_uuid
    } do
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{Ecto.UUID.generate()}"})

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "stray.pdf",
          file_name: "stray.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-orphan",
          user_file_checksum: "user-checksum-orphan",
          size: 5,
          status: "active",
          folder_uuid: folder.uuid,
          user_uuid: user_uuid
        })

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "catalogue"
      assert action.op == :report
      assert action.counts == {1, 0}
      assert action.reason =~ "missing"
      assert action.reason =~ "1 file"
    end

    test "legacy folder of a deleted item → report names the record's status" do
      catalogue = new_catalogue()
      item = new_item(catalogue)
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.trash_item(item)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "deleted"
    end

    test "legacy folder of a live item → not reported as orphan" do
      catalogue = new_catalogue()
      item = new_item(catalogue)
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end

  describe "PDF library report" do
    test "PDFs at root with a configured library folder → one report action", %{
      user_uuid: user_uuid
    } do
      {:ok, pdf_folder} = Storage.create_folder(%{name: "PDF library"})
      Process.put(:pdf_folder, pdf_folder.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {PdfHook, :parent})

      {:ok, file} =
        Storage.create_file(%{
          original_file_name: "manual.pdf",
          file_name: "manual.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-2",
          user_file_checksum: "user-checksum-2",
          size: 20,
          status: "active",
          user_uuid: user_uuid
        })

      {:ok, _pdf} =
        %Pdf{}
        |> Pdf.changeset(%{
          file_uuid: file.uuid,
          original_filename: "manual.pdf",
          byte_size: 20,
          status: "active"
        })
        |> Repo.insert()

      actions = MediaReorganizer.plan(nil, [])
      pdf_action = Enum.find(actions, &(&1.kind == :pdf))

      refute is_nil(pdf_action)
      assert pdf_action.op == :report
      assert {1, 0} = pdf_action.counts
    end

    test "no PDFs at root → no report action" do
      {:ok, pdf_folder} = Storage.create_folder(%{name: "PDF library"})
      Process.put(:pdf_folder, pdf_folder.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {PdfHook, :parent})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :pdf))
    end
  end
end
