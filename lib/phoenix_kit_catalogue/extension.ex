defmodule PhoenixKitCatalogue.Extension do
  @moduledoc """
  Behaviour for a module that adds a "Shop"-style section to the catalogue
  item and/or category forms and owns a namespace under `data` (spec §2
  principle 8, §4 row C4).

  Catalogue never names an implementer — discovery is duck-typed through
  `PhoenixKit.ModuleRegistry`, the same pattern `PhoenixKitAI.Translatable`
  uses for `ai_translatables/0` (see `PhoenixKitCatalogue.Extensions`).
  A host module (e.g. `phoenix_kit_ecommerce`) contributes an implementer
  via its own `catalogue_extensions/0` callback; it structurally
  implements this behaviour without declaring `@behaviour
  PhoenixKitCatalogue.Extension`, so it isn't forced to depend on
  `phoenix_kit_catalogue` at compile time.

  All callbacks except `key/0` and `enabled?/0` are optional — an
  extension can own a namespace and render on only one of the two forms,
  or hold data without rendering anything at all.
  """

  @doc "Namespace under `data` this extension owns, e.g. `\"ecommerce\"`."
  @callback key() :: String.t()

  @doc "Whether the extension's section should render and its namespace be absorbed."
  @callback enabled?() :: boolean()

  @doc """
  Renders the extension's section inside the catalogue item form.

  `assigns` carries `:form`, `:item`, `:data` (the item's `data` map, so
  `data[key()]` is the extension's own current values) and
  `:current_language`.
  """
  @callback item_section(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc "Same as `item_section/1`, for the catalogue category form (`:category` instead of `:item`)."
  @callback category_section(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Validates and shapes the item form's submap for this extension's
  namespace (`params[key()]`, a plain map) into the value to store under
  `data[key()]`. `current` is the namespace's existing value (`data[key()]`
  before this submission, or `%{}`).
  """
  @callback cast_item(params :: map(), current :: map()) ::
              {:ok, map()} | {:error, [{atom(), String.t()}]}

  @doc "Same as `cast_item/2`, for the catalogue category form."
  @callback cast_category(params :: map(), current :: map()) ::
              {:ok, map()} | {:error, [{atom(), String.t()}]}

  @optional_callbacks item_section: 1, category_section: 1, cast_item: 2, cast_category: 2
end
