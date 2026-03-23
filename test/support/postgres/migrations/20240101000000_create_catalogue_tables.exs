defmodule PhoenixKitCatalogue.Test.Repo.Migrations.CreateCatalogueTables do
  use Ecto.Migration

  def up do
    PhoenixKitCatalogue.Migration.up()
  end

  def down do
    PhoenixKitCatalogue.Migration.down()
  end
end
