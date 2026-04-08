defmodule PhoenixKitCatalogue.Test.Repo.Migrations.CatalogueSetup do
  @moduledoc false
  use Ecto.Migration

  def up do
    # V87: Core catalogue tables
    create_if_not_exists table(:phoenix_kit_cat_manufacturers, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:website, :string)
      add(:contact_info, :string)
      add(:logo_url, :string)
      add(:notes, :text)
      add(:status, :string, null: false, default: "active")
      add(:data, :map, default: %{})
      timestamps()
    end

    create_if_not_exists(index(:phoenix_kit_cat_manufacturers, [:status]))

    create_if_not_exists table(:phoenix_kit_cat_suppliers, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:website, :string)
      add(:contact_info, :string)
      add(:notes, :text)
      add(:status, :string, null: false, default: "active")
      add(:data, :map, default: %{})
      timestamps()
    end

    create_if_not_exists(index(:phoenix_kit_cat_suppliers, [:status]))

    create_if_not_exists table(:phoenix_kit_cat_manufacturer_suppliers, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)

      add(
        :manufacturer_uuid,
        references(:phoenix_kit_cat_manufacturers,
          column: :uuid,
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :supplier_uuid,
        references(:phoenix_kit_cat_suppliers,
          column: :uuid,
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      timestamps()
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_cat_manufacturer_suppliers, [:manufacturer_uuid, :supplier_uuid])
    )

    create_if_not_exists table(:phoenix_kit_cat_catalogues, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:status, :string, null: false, default: "active")
      add(:markup_percentage, :decimal, precision: 7, scale: 2, null: false, default: 0)
      add(:data, :map, default: %{})
      timestamps()
    end

    create_if_not_exists(index(:phoenix_kit_cat_catalogues, [:status]))

    create_if_not_exists table(:phoenix_kit_cat_categories, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:position, :integer, null: false, default: 0)
      add(:status, :string, null: false, default: "active")

      add(
        :catalogue_uuid,
        references(:phoenix_kit_cat_catalogues,
          column: :uuid,
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:data, :map, default: %{})
      timestamps()
    end

    create_if_not_exists(index(:phoenix_kit_cat_categories, [:catalogue_uuid]))
    create_if_not_exists(index(:phoenix_kit_cat_categories, [:catalogue_uuid, :position]))
    create_if_not_exists(index(:phoenix_kit_cat_categories, [:status]))

    create_if_not_exists table(:phoenix_kit_cat_items, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:sku, :string)
      add(:base_price, :decimal, precision: 12, scale: 4)
      add(:unit, :string, default: "piece")
      add(:status, :string, null: false, default: "active")

      add(
        :category_uuid,
        references(:phoenix_kit_cat_categories,
          column: :uuid,
          type: :binary_id,
          on_delete: :nilify_all
        )
      )

      add(
        :manufacturer_uuid,
        references(:phoenix_kit_cat_manufacturers,
          column: :uuid,
          type: :binary_id,
          on_delete: :nilify_all
        )
      )

      add(:data, :map, default: %{})
      timestamps()
    end

    create_if_not_exists(index(:phoenix_kit_cat_items, [:sku]))
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
