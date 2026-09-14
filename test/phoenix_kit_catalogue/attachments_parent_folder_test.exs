defmodule PhoenixKitCatalogue.AttachmentsParentFolderTest do
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  defmodule Hook do
    def parent(:item, _actor), do: {:ok, Process.get(:items_container)}
    def parent(_, _), do: nil
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_catalogue, :attachments_parent_folder) end)
    :ok
  end

  test "parent_folder_uuid is nil without config" do
    assert Attachments.parent_folder_uuid(%Item{uuid: Ecto.UUID.generate()}, nil) == nil
  end

  test "parent_folder_uuid consults the hook per resource kind" do
    {:ok, container} = Storage.create_folder(%{name: "Catalogue items"})
    Process.put(:items_container, container.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    assert Attachments.parent_folder_uuid(%Item{uuid: Ecto.UUID.generate()}, nil) ==
             container.uuid

    assert Attachments.parent_folder_uuid(%Category{uuid: Ecto.UUID.generate()}, nil) == nil
  end

  test "find_folder_by_name looks under the parent first, then at root" do
    {:ok, container} = Storage.create_folder(%{name: "Catalogue items"})
    uuid = Ecto.UUID.generate()
    name = "catalogue-item-#{uuid}"
    {:ok, at_root} = Storage.create_folder(%{name: name})

    assert %{uuid: found} = Attachments.find_folder_by_name(name, container.uuid)
    assert found == at_root.uuid

    {:ok, nested} = Storage.create_folder(%{name: name, parent_uuid: container.uuid})
    assert %{uuid: found2} = Attachments.find_folder_by_name(name, container.uuid)
    assert found2 == nested.uuid
  end
end
