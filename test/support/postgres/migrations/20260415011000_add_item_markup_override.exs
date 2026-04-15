defmodule PhoenixKitCatalogue.Test.Repo.Migrations.AddItemMarkupOverride do
  @moduledoc """
  Mirrors core PhoenixKit's V97 migration for the catalogue module's
  local test DB: adds a nullable `markup_percentage DECIMAL(7, 2)` column
  to `phoenix_kit_cat_items`. `NULL` = inherit the catalogue's markup,
  any value (including `0`) overrides it.
  """

  use Ecto.Migration

  def up do
    alter table(:phoenix_kit_cat_items) do
      add_if_not_exists(:markup_percentage, :decimal, precision: 7, scale: 2)
    end
  end

  def down do
    alter table(:phoenix_kit_cat_items) do
      remove_if_exists(:markup_percentage, :decimal)
    end
  end
end
