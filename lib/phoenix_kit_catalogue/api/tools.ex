defmodule PhoenixKitCatalogue.API.Tools do
  @moduledoc false
  # The catalogue's tool declarations. `PhoenixKitCatalogue.api_tools/0`
  # returns `all/0`; core's registry validates each struct and tags it with this module.
  #
  # Scope -> role permission, all permission "catalogue":
  #   catalogue.products:read      list_products, get_products
  #   catalogue.products:write     create_products, update_products, set_translations
  #   catalogue.products:delete    delete_products
  #   catalogue.categories:read    list_categories
  #   catalogue.categories:write   upsert_categories

  alias PhoenixKit.API.Tool
  alias PhoenixKitCatalogue.API.Schemas

  @permission "catalogue"

  @spec all() :: [Tool.t()]
  def all do
    [
      list_products(),
      get_products(),
      create_products(),
      update_products(),
      set_translations(),
      list_categories()
    ]
  end

  defp list_products do
    Tool.new!(
      name: "catalogue.list_products",
      audience: :admin,
      scope: "catalogue.products:read",
      permission: @permission,
      title: "List products",
      description:
        "Lists the items of one catalogue, oldest change first, 20 per page (up to 100). " <>
          "Filter by category_id, status, q (a text match on name, description and sku) and updated_since " <>
          "(inclusive, ISO 8601 with a zone). Trashed items are not listed unless include_deleted is true " <>
          "(then they come back with status deleted, which is how an export sees deletions). " <>
          "Follow next_cursor until it is null; count is the exact number of matches. For an incremental " <>
          "export remember the largest updated_at you saw and pass it as updated_since next time; rows at " <>
          "the boundary repeat, de-duplicate by id. fields picks what to return.",
      input_schema: Schemas.list_products(),
      output_schema: Schemas.list_products_output(),
      handler: {PhoenixKitCatalogue.API.ListProducts, :call},
      annotations: %{read_only: true, idempotent: true}
    )
  end

  defp get_products do
    Tool.new!(
      name: "catalogue.get_products",
      audience: :admin,
      scope: "catalogue.products:read",
      permission: @permission,
      title: "Get products",
      description:
        "Reads up to 50 items by reference ({id} or {sku} or {external_id}); the answer has one result " <>
          "per reference, in the same order. A sku may match several items: such a reference answers " <>
          "ambiguous_ref with the candidate ids. fields picks what to return (default: everything). " <>
          "The shop field (data.ecommerce, never cost_per_item) is returned only when the key also " <>
          "holds ecommerce.prices:read.",
      input_schema: Schemas.get_products(),
      output_schema: Schemas.batch_output(%{"item" => %{"type" => "object"}}),
      handler: {PhoenixKitCatalogue.API.GetProducts, :call},
      annotations: %{read_only: true, idempotent: true},
      max_items: 50
    )
  end

  defp create_products do
    Tool.new!(
      name: "catalogue.create_products",
      audience: :admin,
      scope: "catalogue.products:write",
      permission: @permission,
      title: "Create products",
      description:
        "Creates up to 500 items in one catalogue. Every row needs a name and at least one of sku and " <>
          "external_id (so a retried request cannot create the item twice). A row whose sku or external_id " <>
          "already exists is skipped with already_exists and the existing id: nothing is ever overwritten. " <>
          "New items have no price and are not visible in the shop until ecommerce.set_prices and " <>
          "ecommerce.set_availability are called. Rows are independent; each answers created, skipped or error.",
      input_schema: Schemas.create_products(),
      output_schema: Schemas.batch_output(),
      handler: {PhoenixKitCatalogue.API.CreateProducts, :call},
      annotations: %{idempotent: false},
      max_items: 500
    )
  end

  defp update_products do
    Tool.new!(
      name: "catalogue.update_products",
      audience: :admin,
      scope: "catalogue.products:write",
      permission: @permission,
      title: "Update products",
      description:
        "Changes up to 500 items, each named by a reference ({id} or {sku} or {external_id}) and a changes " <>
          "object with any of name, description, sku, external_id, category_id, status (active, inactive or " <>
          "discontinued), unit and attributes. null clears description, sku, external_id and category_id. " <>
          "Fields not listed stay as they are, and so does everything the tool does not own (prices, shop " <>
          "data, translations). A rename does not change the item's URL slug. Rows are independent; each " <>
          "answers updated, unchanged or error.",
      input_schema: Schemas.update_products(),
      output_schema: Schemas.batch_output(),
      handler: {PhoenixKitCatalogue.API.UpdateProducts, :call},
      annotations: %{idempotent: true},
      max_items: 500
    )
  end

  defp set_translations do
    Tool.new!(
      name: "catalogue.set_translations",
      audience: :admin,
      scope: "catalogue.products:write",
      permission: @permission,
      title: "Set product translations",
      description:
        "Sets the name, description, URL slug and SEO title and description of up to 500 items, per language. " <>
          "Each item is named by a reference and carries a translations object keyed by language code " <>
          "(a full code of an enabled language such as de-DE, or a bare code that matches exactly one). " <>
          "The item's primary language is changed with catalogue.update_products instead. null clears a field. " <>
          "A slug is cut to 60 characters at a word boundary; one that another item already uses is refused, " <>
          "and a missing slug is generated from the name (made unique with -2, -3). An existing slug is never " <>
          "rewritten by a name. Rows are independent; each answers updated, unchanged or error.",
      input_schema: Schemas.set_translations(),
      output_schema: Schemas.batch_output(),
      handler: {PhoenixKitCatalogue.API.SetTranslations, :call},
      annotations: %{idempotent: true},
      max_items: 500
    )
  end

  defp list_categories do
    Tool.new!(
      name: "catalogue.list_categories",
      audience: :admin,
      scope: "catalogue.categories:read",
      permission: @permission,
      title: "List categories",
      description:
        "Returns the category tree of one catalogue: each node has id, external_id, name, names " <>
          "(the name in every language that has one), position, status and children, siblings ordered " <>
          "by position then name.",
      input_schema: Schemas.list_categories(),
      output_schema: Schemas.categories_output(),
      handler: {PhoenixKitCatalogue.API.ListCategories, :call},
      annotations: %{read_only: true, idempotent: true}
    )
  end
end
