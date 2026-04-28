defmodule PhoenixKitCatalogue.Test.Repo.Migrations.PhoenixKitStorage do
  @moduledoc """
  Mirrors the subset of core PhoenixKit's Storage tables that the
  catalogue's `MediaSelectorModal` LiveComponent and the `Attachments`
  module read at form mount time. Only the columns the catalogue's
  test paths touch are populated; the prod migrations carry more.

  Without these tables, every `live/2` against `CatalogueFormLive`,
  `CategoryFormLive`, or `ItemFormLive` crashes inside
  `MediaSelectorModal.update/2` with
  `relation "phoenix_kit_buckets" does not exist`.
  """

  use Ecto.Migration

  def up do
    create_if_not_exists table(:phoenix_kit_buckets, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:provider, :string, default: "s3")
      add(:region, :string)
      add(:endpoint, :string)
      add(:bucket_name, :string)
      add(:access_key_id, :string)
      add(:secret_access_key, :string)
      add(:cdn_url, :string)
      add(:access_type, :string, default: "public")
      add(:enabled, :boolean, default: false)
      add(:priority, :integer, default: 0)
      add(:max_size_mb, :integer, default: 100)
      timestamps()
    end

    create_if_not_exists table(:phoenix_kit_media_folders, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:color, :string)
      add(:parent_uuid, :binary_id)
      add(:user_uuid, :binary_id)
      add(:status, :string, default: "active")
      add(:data, :map, default: %{})
      timestamps()
    end

    # Defensive: if an older test DB already created the table without
    # `color`, add it now. ALTER … ADD COLUMN IF NOT EXISTS is a no-op
    # when the column already exists.
    execute("ALTER TABLE phoenix_kit_media_folders ADD COLUMN IF NOT EXISTS color varchar(255)")

    create_if_not_exists(index(:phoenix_kit_media_folders, [:parent_uuid]))
    create_if_not_exists(index(:phoenix_kit_media_folders, [:user_uuid]))

    create_if_not_exists table(:phoenix_kit_files, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:file_name, :string)
      add(:original_file_name, :string)
      add(:file_path, :string)
      add(:mime_type, :string)
      add(:file_type, :string)
      add(:ext, :string)
      add(:file_checksum, :string)
      add(:user_file_checksum, :string)
      add(:size, :integer)
      add(:width, :integer)
      add(:height, :integer)
      add(:duration, :integer)
      add(:bucket_uuid, :binary_id)
      add(:folder_uuid, :binary_id)
      add(:user_uuid, :binary_id)
      add(:status, :string, default: "active")
      add(:trashed_at, :utc_datetime)
      add(:metadata, :map, default: %{})
      timestamps()
    end

    create_if_not_exists(index(:phoenix_kit_files, [:folder_uuid]))
    create_if_not_exists(index(:phoenix_kit_files, [:user_uuid]))

    create_if_not_exists table(:phoenix_kit_media_folder_links, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:folder_uuid, :binary_id, null: false)
      add(:file_uuid, :binary_id, null: false)
      timestamps()
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_media_folder_links, [:folder_uuid, :file_uuid])
    )
  end

  def down do
    drop_if_exists(table(:phoenix_kit_media_folder_links))
    drop_if_exists(table(:phoenix_kit_files))
    drop_if_exists(table(:phoenix_kit_media_folders))
    drop_if_exists(table(:phoenix_kit_buckets))
  end
end
