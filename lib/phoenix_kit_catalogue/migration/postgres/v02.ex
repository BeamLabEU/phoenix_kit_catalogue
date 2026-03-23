defmodule PhoenixKitCatalogue.Migration.Postgres.V02 do
  @moduledoc """
  V02: Add status column to categories for soft-delete support.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_cat_categories, prefix: prefix) do
      add_if_not_exists(:status, :string, default: "active", size: 20)
    end

    create_if_not_exists(
      index(:phoenix_kit_cat_categories, [:status], prefix: prefix)
    )
  end

  def down(%{prefix: prefix} = _opts) do
    drop_if_exists(index(:phoenix_kit_cat_categories, [:status], prefix: prefix))

    alter table(:phoenix_kit_cat_categories, prefix: prefix) do
      remove_if_exists(:status, :string)
    end
  end
end
