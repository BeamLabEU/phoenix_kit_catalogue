defmodule PhoenixKitCatalogue.Test.Repo.Migrations.AddV102SmartCatalogues do
  @moduledoc """
  Mirrors core PhoenixKit's V102 migration for the catalogue module's
  local test DB:

    * `phoenix_kit_cat_catalogues.discount_percentage` — per-catalogue
      default discount (not-null, default 0).
    * `phoenix_kit_cat_catalogues.kind` — `standard` / `smart`.
    * `phoenix_kit_cat_items.discount_percentage` — nullable override.
    * `phoenix_kit_cat_items.default_value` / `default_unit` — fallback
      for smart-rule rows with NULL `value` / `unit`.
    * `phoenix_kit_cat_item_catalogue_rules` — one row per
      `(item, referenced_catalogue)` pair for smart-catalogue items.
    * CHECK constraints mirroring the prod migration so the DB enforces
      the closed enum for `kind` and the numeric ranges, catching drift
      between prod and test schemas.
  """

  use Ecto.Migration

  def up do
    alter table(:phoenix_kit_cat_catalogues) do
      add_if_not_exists(:discount_percentage, :decimal,
        precision: 7,
        scale: 2,
        null: false,
        default: 0
      )

      add_if_not_exists(:kind, :string, size: 20, null: false, default: "standard")
    end

    alter table(:phoenix_kit_cat_items) do
      add_if_not_exists(:discount_percentage, :decimal, precision: 7, scale: 2)
      add_if_not_exists(:default_value, :decimal, precision: 12, scale: 4)
      add_if_not_exists(:default_unit, :string, size: 20)
    end

    create_if_not_exists table(:phoenix_kit_cat_item_catalogue_rules, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)

      add(
        :item_uuid,
        references(:phoenix_kit_cat_items,
          column: :uuid,
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :referenced_catalogue_uuid,
        references(:phoenix_kit_cat_catalogues,
          column: :uuid,
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:value, :decimal, precision: 12, scale: 4)
      add(:unit, :string, size: 20)
      add(:position, :integer, null: false, default: 0)

      timestamps()
    end

    create_if_not_exists(
      unique_index(
        :phoenix_kit_cat_item_catalogue_rules,
        [:item_uuid, :referenced_catalogue_uuid],
        name: :phoenix_kit_cat_item_catalogue_rules_pair_index
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_cat_item_catalogue_rules, [:item_uuid],
        name: :phoenix_kit_cat_item_catalogue_rules_item_index
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_cat_item_catalogue_rules, [:referenced_catalogue_uuid],
        name: :phoenix_kit_cat_item_catalogue_rules_referenced_index
      )
    )

    # CHECK constraints — mirror the prod migration so the DB enforces
    # the closed vocab for `kind` and the numeric ranges. Keeps prod
    # and test schemas aligned and catches regressions at the DB layer.
    execute(
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT FROM pg_constraint
          WHERE conname = 'phoenix_kit_cat_catalogues_kind_check'
        ) THEN
          ALTER TABLE phoenix_kit_cat_catalogues
            ADD CONSTRAINT phoenix_kit_cat_catalogues_kind_check
            CHECK (kind IN ('standard', 'smart'));
        END IF;

        IF NOT EXISTS (
          SELECT FROM pg_constraint
          WHERE conname = 'phoenix_kit_cat_catalogues_discount_pct_check'
        ) THEN
          ALTER TABLE phoenix_kit_cat_catalogues
            ADD CONSTRAINT phoenix_kit_cat_catalogues_discount_pct_check
            CHECK (discount_percentage >= 0 AND discount_percentage <= 100);
        END IF;

        IF NOT EXISTS (
          SELECT FROM pg_constraint
          WHERE conname = 'phoenix_kit_cat_items_discount_pct_check'
        ) THEN
          ALTER TABLE phoenix_kit_cat_items
            ADD CONSTRAINT phoenix_kit_cat_items_discount_pct_check
            CHECK (discount_percentage IS NULL OR
                   (discount_percentage >= 0 AND discount_percentage <= 100));
        END IF;

        IF NOT EXISTS (
          SELECT FROM pg_constraint
          WHERE conname = 'phoenix_kit_cat_items_default_value_check'
        ) THEN
          ALTER TABLE phoenix_kit_cat_items
            ADD CONSTRAINT phoenix_kit_cat_items_default_value_check
            CHECK (default_value IS NULL OR default_value >= 0);
        END IF;

        IF NOT EXISTS (
          SELECT FROM pg_constraint
          WHERE conname = 'phoenix_kit_cat_item_catalogue_rules_value_check'
        ) THEN
          ALTER TABLE phoenix_kit_cat_item_catalogue_rules
            ADD CONSTRAINT phoenix_kit_cat_item_catalogue_rules_value_check
            CHECK (value IS NULL OR value >= 0);
        END IF;
      END $$;
      """,
      """
      ALTER TABLE phoenix_kit_cat_item_catalogue_rules
        DROP CONSTRAINT IF EXISTS phoenix_kit_cat_item_catalogue_rules_value_check;

      ALTER TABLE phoenix_kit_cat_items
        DROP CONSTRAINT IF EXISTS phoenix_kit_cat_items_default_value_check,
        DROP CONSTRAINT IF EXISTS phoenix_kit_cat_items_discount_pct_check;

      ALTER TABLE phoenix_kit_cat_catalogues
        DROP CONSTRAINT IF EXISTS phoenix_kit_cat_catalogues_kind_check,
        DROP CONSTRAINT IF EXISTS phoenix_kit_cat_catalogues_discount_pct_check;
      """
    )
  end

  def down do
    drop_if_exists(table(:phoenix_kit_cat_item_catalogue_rules))

    alter table(:phoenix_kit_cat_items) do
      remove_if_exists(:default_unit, :string)
      remove_if_exists(:default_value, :decimal)
      remove_if_exists(:discount_percentage, :decimal)
    end

    alter table(:phoenix_kit_cat_catalogues) do
      remove_if_exists(:kind, :string)
      remove_if_exists(:discount_percentage, :decimal)
    end
  end
end
