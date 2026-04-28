defmodule PhoenixKitCatalogue.Test.Repo.Migrations.AddV103NestedCategories do
  @moduledoc """
  Mirrors core PhoenixKit's V103 migration: adds the self-FK
  `parent_uuid` to `phoenix_kit_cat_categories`, turning the flat
  taxonomy into an arbitrary-depth tree. NULL means root.

  V103 deliberately omits `ON DELETE CASCADE` on the self-FK because
  the context-layer cascade walks the subtree manually (see
  `Catalogue.permanently_delete_category/2`); a DB-level cascade would
  fight the application semantics on partial deletes.
  """

  use Ecto.Migration

  def up do
    alter table(:phoenix_kit_cat_categories) do
      add_if_not_exists(
        :parent_uuid,
        references(:phoenix_kit_cat_categories,
          column: :uuid,
          type: :binary_id,
          on_delete: :nilify_all
        )
      )
    end

    create_if_not_exists(index(:phoenix_kit_cat_categories, [:parent_uuid]))
  end

  def down do
    alter table(:phoenix_kit_cat_categories) do
      remove_if_exists(:parent_uuid, :binary_id)
    end
  end
end
