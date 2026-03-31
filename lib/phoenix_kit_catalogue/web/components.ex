defmodule PhoenixKitCatalogue.Web.Components do
  @moduledoc """
  Reusable UI components for the Catalogue module.

  All components are designed to be opt-in — features are off by default and
  enabled via attributes. Import into any LiveView with:

      import PhoenixKitCatalogue.Web.Components

  ## Components

    * `search_input/1` — search bar with debounce and clear button
    * `item_table/1` — configurable item table with selectable columns
    * `empty_state/1` — centered empty state card with message and optional action

  ## Examples

      <%!-- Minimal item table: just name and SKU --%>
      <.item_table items={@items} columns={[:name, :sku]} />

      <%!-- Full-featured table with search, pricing, and actions --%>
      <.item_table
        items={@items}
        columns={[:name, :sku, :base_price, :price, :unit, :status, :category, :manufacturer]}
        markup_percentage={@catalogue.markup_percentage}
        edit_path={&Paths.item_edit/1}
        on_delete="delete_item"
      />

      <%!-- Search bar --%>
      <.search_input query={@search_query} placeholder="Search items..." />
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.Badge, only: [status_badge: 1]

  alias PhoenixKitCatalogue.Schemas.Item

  # ═══════════════════════════════════════════════════════════════════
  # Search input
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders a search input with debounce and clear button.

  Emits `search` event with `%{"query" => value}` on change/submit,
  and `clear_search` on clear button click. Override event names via attrs.

  ## Attributes

    * `query` — current search query string (required)
    * `placeholder` — input placeholder text (default: "Search...")
    * `on_search` — event name for search (default: "search")
    * `on_clear` — event name for clear (default: "clear_search")
    * `debounce` — debounce ms (default: 300)
    * `class` — additional CSS classes on the wrapper div
  """
  attr :query, :string, required: true
  attr :placeholder, :string, default: "Search..."
  attr :on_search, :string, default: "search"
  attr :on_clear, :string, default: "clear_search"
  attr :debounce, :integer, default: 300
  attr :class, :string, default: ""

  def search_input(assigns) do
    ~H"""
    <div class={["flex gap-2", @class]}>
      <form phx-change={@on_search} phx-submit={@on_search} class="flex-1 relative">
        <input
          type="text"
          name="query"
          value={@query}
          placeholder={@placeholder}
          class="input input-bordered input-sm w-full pr-8"
          phx-debounce={@debounce}
          autocomplete="off"
        />
        <button
          :if={@query != ""}
          type="button"
          phx-click={@on_clear}
          class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-base-content cursor-pointer"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </form>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Search results summary
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders a search results count summary line.

  ## Attributes

    * `count` — number of results (required)
    * `query` — the search query string (required)
  """
  attr :count, :integer, required: true
  attr :query, :string, required: true

  def search_results_summary(assigns) do
    ~H"""
    <span class="text-sm text-base-content/60">
      {@count} result{if @count != 1, do: "s"} for "{@query}"
    </span>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Empty state
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders an empty state card with a message and optional action slot.

  ## Attributes

    * `message` — the text to display (required)

  ## Slots

    * `inner_block` — optional action content (buttons, links)
  """
  attr :message, :string, required: true
  slot :inner_block

  def empty_state(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{@message}</p>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item table
  # ═══════════════════════════════════════════════════════════════════

  @all_columns ~w(name sku base_price price unit status category catalogue manufacturer)a

  @doc """
  Renders a configurable item table.

  Columns are opt-in — only the columns you list are shown. Actions (edit, delete,
  restore) are opt-in via their respective attributes.

  ## Attributes

    * `items` — list of items to display (required)
    * `columns` — list of column atoms to show (default: `[:name, :sku, :base_price, :status]`)
      Available: #{inspect(@all_columns)}
    * `markup_percentage` — catalogue markup for `:price` column (required if `:price` in columns)
    * `edit_path` — 1-arity function `(uuid -> path)` to enable edit links
    * `on_delete` — event name for soft-delete button (e.g. `"delete_item"`)
    * `on_restore` — event name for restore button (e.g. `"restore_item"`)
    * `on_permanent_delete` — event name for permanent delete (e.g. `"show_delete_confirm"`)
    * `permanent_delete_type` — type string passed as `phx-value-type` (e.g. `"item"`)
    * `catalogue_path` — 1-arity function `(uuid -> path)` for catalogue links in `:catalogue` column
    * `variant` — table variant: `"default"` or `"zebra"` (default: `"default"`)
    * `size` — table size: `"xs"`, `"sm"`, `"md"`, `"lg"` (default: `"sm"`)
    * `wrapper_class` — override wrapper CSS class
  """
  attr :items, :list, required: true
  attr :columns, :list, default: [:name, :sku, :base_price, :status]
  attr :markup_percentage, :any, default: nil
  attr :edit_path, :any, default: nil
  attr :on_delete, :string, default: nil
  attr :on_restore, :string, default: nil
  attr :on_permanent_delete, :string, default: nil
  attr :permanent_delete_type, :string, default: "item"
  attr :catalogue_path, :any, default: nil
  attr :variant, :string, default: "default"
  attr :size, :string, default: "sm"
  attr :wrapper_class, :string, default: nil

  def item_table(assigns) do
    assigns = assign(assigns, :has_actions, has_actions?(assigns))

    ~H"""
    <.table_default variant={@variant} size={@size} wrapper_class={@wrapper_class}>
      <.table_default_header>
        <.table_default_row>
          <.table_default_header_cell :for={col <- @columns}>{column_label(col)}</.table_default_header_cell>
          <.table_default_header_cell :if={@has_actions} class="text-right">Actions</.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.table_default_body>
        <.table_default_row :for={item <- @items}>
          <.item_cell :for={col <- @columns} column={col} item={item} markup_percentage={@markup_percentage} catalogue_path={@catalogue_path} />
          <.item_actions
            :if={@has_actions}
            item={item}
            edit_path={@edit_path}
            on_delete={@on_delete}
            on_restore={@on_restore}
            on_permanent_delete={@on_permanent_delete}
            permanent_delete_type={@permanent_delete_type}
          />
        </.table_default_row>
      </.table_default_body>
    </.table_default>
    """
  end

  # ── Column cells ───────────────────────────────────────────────

  attr :column, :atom, required: true
  attr :item, :any, required: true
  attr :markup_percentage, :any, default: nil
  attr :catalogue_path, :any, default: nil

  defp item_cell(%{column: :name} = assigns) do
    ~H"""
    <.table_default_cell class="font-medium">{@item.name}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :sku} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm font-mono text-base-content/60">{@item.sku || "—"}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :base_price} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm">{format_price(@item.base_price)}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :price} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm font-semibold">{format_price(Item.sale_price(@item, @markup_percentage))}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :unit} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm">{format_unit(@item.unit)}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :status} = assigns) do
    ~H"""
    <.table_default_cell><.status_badge status={@item.status} size={:xs} /></.table_default_cell>
    """
  end

  defp item_cell(%{column: :category} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm text-base-content/60">{if @item.category, do: @item.category.name, else: "—"}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :catalogue} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm">
      <.link
        :if={@item.category && @catalogue_path}
        navigate={@catalogue_path.(@item.category.catalogue.uuid)}
        class="link link-hover"
      >
        {@item.category.catalogue.name}
      </.link>
      <span :if={!@item.category || !@catalogue_path} class="text-base-content/60">—</span>
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :manufacturer} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm text-base-content/60">{if @item.manufacturer, do: @item.manufacturer.name, else: "—"}</.table_default_cell>
    """
  end

  # ── Action cell ────────────────────────────────────────────────

  attr :item, :any, required: true
  attr :edit_path, :any, default: nil
  attr :on_delete, :string, default: nil
  attr :on_restore, :string, default: nil
  attr :on_permanent_delete, :string, default: nil
  attr :permanent_delete_type, :string, default: "item"

  defp item_actions(assigns) do
    ~H"""
    <.table_default_cell class="text-right whitespace-nowrap">
      <.table_row_menu id={"item-action-#{@item.uuid}"} mode="auto">
        <.table_row_menu_link :if={@edit_path} navigate={@edit_path.(@item.uuid)} icon="hero-pencil" label="Edit" />
        <.table_row_menu_divider :if={@edit_path && (@on_delete || @on_restore)} />
        <.table_row_menu_button :if={@on_delete} phx-click={@on_delete} phx-value-uuid={@item.uuid} icon="hero-trash" label="Delete" variant="error" />
        <.table_row_menu_button :if={@on_restore} phx-click={@on_restore} phx-value-uuid={@item.uuid} icon="hero-arrow-path" label="Restore" variant="success" />
        <.table_row_menu_divider :if={@on_restore && @on_permanent_delete} />
        <.table_row_menu_button :if={@on_permanent_delete} phx-click={@on_permanent_delete} phx-value-uuid={@item.uuid} phx-value-type={@permanent_delete_type} icon="hero-trash" label="Delete Forever" variant="error" />
      </.table_row_menu>
    </.table_default_cell>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp has_actions?(assigns) do
    assigns[:edit_path] != nil or assigns[:on_delete] != nil or
      assigns[:on_restore] != nil or assigns[:on_permanent_delete] != nil
  end

  defp column_label(:name), do: "Name"
  defp column_label(:sku), do: "SKU"
  defp column_label(:base_price), do: "Base Price"
  defp column_label(:price), do: "Price"
  defp column_label(:unit), do: "Unit"
  defp column_label(:status), do: "Status"
  defp column_label(:category), do: "Category"
  defp column_label(:catalogue), do: "Catalogue"
  defp column_label(:manufacturer), do: "Manufacturer"

  defp format_price(nil), do: "—"
  defp format_price(price), do: Decimal.to_string(price, :normal)

  defp format_unit("piece"), do: "pc"
  defp format_unit("m2"), do: "m²"
  defp format_unit("running_meter"), do: "rm"
  defp format_unit(other), do: other
end
