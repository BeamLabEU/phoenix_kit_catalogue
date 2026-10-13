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
  def all, do: [list_products(), get_products()]

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
end
