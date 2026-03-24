defmodule PhoenixKitCatalogue.Test.Repo.Migrations.CreateCatalogueTables do
  @moduledoc """
  Test-only migration that creates Catalogue tables.
  Production migrations live in PhoenixKit core (V87).
  """
  use Ecto.Migration

  def up do
    create_if_not_exists table(:phoenix_kit_cat_manufacturers,
                            primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:website, :string, size: 500)
      add(:contact_info, :string, size: 500)
      add(:logo_url, :string, size: 500)
      add(:notes, :text)
      add(:status, :string, default: "active", size: 20)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_cat_manufacturers, [:status]))

    create_if_not_exists table(:phoenix_kit_cat_suppliers,
                            primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:website, :string, size: 500)
      add(:contact_info, :string, size: 500)
      add(:notes, :text)
      add(:status, :string, default: "active", size: 20)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_cat_suppliers, [:status]))

    create_if_not_exists table(:phoenix_kit_cat_manufacturer_suppliers,
                            primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:manufacturer_uuid,
        references(:phoenix_kit_cat_manufacturers,
          column: :uuid, type: :uuid, on_delete: :delete_all),
        null: false)

      add(:supplier_uuid,
        references(:phoenix_kit_cat_suppliers,
          column: :uuid, type: :uuid, on_delete: :delete_all),
        null: false)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_cat_manufacturer_suppliers,
        [:manufacturer_uuid, :supplier_uuid]))

    create_if_not_exists table(:phoenix_kit_cat_catalogues,
                            primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:status, :string, default: "active", size: 20)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_cat_catalogues, [:status]))

    create_if_not_exists table(:phoenix_kit_cat_categories,
                            primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:position, :integer, default: 0)
      add(:status, :string, default: "active", size: 20)

      add(:catalogue_uuid,
        references(:phoenix_kit_cat_catalogues,
          column: :uuid, type: :uuid, on_delete: :delete_all),
        null: false)

      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_cat_categories, [:catalogue_uuid]))
    create_if_not_exists(index(:phoenix_kit_cat_categories, [:catalogue_uuid, :position]))
    create_if_not_exists(index(:phoenix_kit_cat_categories, [:status]))

    create_if_not_exists table(:phoenix_kit_cat_items,
                            primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:sku, :string, size: 100)
      add(:price, :decimal, precision: 12, scale: 2)
      add(:unit, :string, default: "piece", size: 20)
      add(:status, :string, default: "active", size: 20)

      add(:category_uuid,
        references(:phoenix_kit_cat_categories,
          column: :uuid, type: :uuid, on_delete: :nilify_all))

      add(:manufacturer_uuid,
        references(:phoenix_kit_cat_manufacturers,
          column: :uuid, type: :uuid, on_delete: :nilify_all))

      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_cat_items, [:sku], where: "sku IS NOT NULL"))
    create_if_not_exists(index(:phoenix_kit_cat_items, [:category_uuid]))
    create_if_not_exists(index(:phoenix_kit_cat_items, [:manufacturer_uuid]))
    create_if_not_exists(index(:phoenix_kit_cat_items, [:status]))
  end

  def down do
    drop_if_exists(table(:phoenix_kit_cat_items))
    drop_if_exists(table(:phoenix_kit_cat_categories))
    drop_if_exists(table(:phoenix_kit_cat_catalogues))
    drop_if_exists(table(:phoenix_kit_cat_manufacturer_suppliers))
    drop_if_exists(table(:phoenix_kit_cat_suppliers))
    drop_if_exists(table(:phoenix_kit_cat_manufacturers))
  end
end
