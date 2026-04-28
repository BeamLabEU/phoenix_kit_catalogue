defmodule PhoenixKitCatalogue.Test.Repo.Migrations.PhoenixKitSettings do
  @moduledoc """
  Mirrors core PhoenixKit's settings table so tests that hit
  `Settings.get_*_setting/2` (e.g. `enabled?/0`) don't blow up the
  sandbox transaction with `column "module" does not exist`.

  Column shape mirrors `phoenix_kit/priv/repo/migrations/V41_settings_table.exs`
  exactly (uuid + key + value + value_json + module + date_added +
  date_updated). Adding the table is cheaper than relying on
  `enabled?/0`'s rescue — that path also catches sandbox-shutdown
  exits, which is fine for production but produces a 1-in-N flaky test.
  """

  use Ecto.Migration

  def up do
    create_if_not_exists table(:phoenix_kit_settings, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:key, :string, null: false)
      add(:value, :string)
      add(:value_json, :map)
      add(:module, :string)
      add(:date_added, :utc_datetime, null: false, default: fragment("now()"))
      add(:date_updated, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(unique_index(:phoenix_kit_settings, [:key]))
    create_if_not_exists(index(:phoenix_kit_settings, [:module]))
  end

  def down do
    drop_if_exists(table(:phoenix_kit_settings))
  end
end
