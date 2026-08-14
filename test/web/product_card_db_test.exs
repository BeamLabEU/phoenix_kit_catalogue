defmodule PhoenixKitCatalogue.Web.Components.ProductCardDBTest do
  @moduledoc """
  DB-backed tests for `ProductCard.resolve_images/1`: the folder image
  listing (exercising the real `Storage.list_files_in_scope/2` signature so a
  rescue can't silently mask a wrong call) and the broken/trashed featured
  filtering.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Web.Components.ProductCard

  defp create_folder(user_uuid) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: "pc-folder-#{System.unique_integer([:positive])}",
        user_uuid: user_uuid
      })

    folder.uuid
  end

  setup do
    # Files carry a CHECK (user_uuid OR parent_file_uuid); give them an owner.
    user_uuid = UUIDv7.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(user_uuid),
        "pc-db-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    {:ok, user_uuid: user_uuid}
  end

  defp insert_image(user_uuid, folder_uuid, name, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = UUIDv7.generate()

    Repo.insert!(%StorageFile{
      uuid: uuid,
      original_file_name: name,
      file_name: name,
      mime_type: "image/jpeg",
      file_type: Keyword.get(opts, :file_type, "image"),
      ext: "jpg",
      file_checksum: "chk-#{uuid}",
      user_file_checksum: "uchk-#{uuid}",
      size: 1,
      status: Keyword.get(opts, :status, "active"),
      system_managed: false,
      user_uuid: user_uuid,
      folder_uuid: folder_uuid,
      inserted_at: now,
      updated_at: now
    })

    uuid
  end

  test "lists the folder's live images, featured first, excluding trashed + non-image", %{
    user_uuid: user
  } do
    folder = create_folder(user)
    featured = insert_image(user, folder, "main.jpg", [])
    other = insert_image(user, folder, "other.jpg", [])
    _trashed = insert_image(user, folder, "gone.jpg", status: "trashed")
    _document = insert_image(user, folder, "doc.pdf", file_type: "document")

    item = %Item{data: %{"featured_image_uuid" => featured, "files_folder_uuid" => folder}}

    images = ProductCard.resolve_images(item)
    uuids = Enum.map(images, & &1.uuid)

    # Featured comes first; the other live image is present; trashed + the
    # non-image are excluded; featured is not duplicated.
    assert hd(uuids) == featured
    assert other in uuids
    assert length(images) == 2
  end

  test "drops a featured pointer whose file no longer exists (no broken image)" do
    item = %Item{data: %{"featured_image_uuid" => UUIDv7.generate()}}

    assert ProductCard.resolve_images(item) == []
  end

  test "drops a trashed featured image", %{user_uuid: user} do
    folder = create_folder(user)
    featured = insert_image(user, folder, "trashed.jpg", status: "trashed")

    item = %Item{data: %{"featured_image_uuid" => featured}}

    assert ProductCard.resolve_images(item) == []
  end
end
