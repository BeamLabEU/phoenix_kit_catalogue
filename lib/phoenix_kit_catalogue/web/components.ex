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
      <.search_input query={@search_query} placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Search items...")} />
  """

  use Phoenix.Component

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKitCatalogue.Schemas.Item

  # ── Local status badge (catalogue statuses don't match upstream badge variants)

  @doc false
  attr(:status, :string, required: true)
  attr(:size, :atom, default: :sm)

  def status_badge(assigns) do
    ~H"""
    <div class={["badge", status_class(@status), size_class(@size)]}>
      {String.capitalize(@status)}
    </div>
    """
  end

  defp status_class("active"), do: "badge-success"
  defp status_class("archived"), do: "badge-ghost"
  defp status_class("deleted"), do: "badge-error"
  defp status_class("inactive"), do: "badge-warning"
  defp status_class(_), do: "badge-neutral"

  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: ""
  defp size_class(:lg), do: "badge-lg"
  defp size_class(_), do: ""

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
  attr(:query, :string, required: true)
  attr(:placeholder, :string, default: "Search...")
  attr(:on_search, :string, default: "search")
  attr(:on_clear, :string, default: "clear_search")
  attr(:debounce, :integer, default: 300)
  attr(:class, :string, default: "")

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
  attr(:count, :integer, required: true)
  attr(:query, :string, required: true)

  def search_results_summary(assigns) do
    ~H"""
    <span class="text-sm text-base-content/60">
      {Gettext.ngettext(PhoenixKitWeb.Gettext, "%{count} result for \"%{query}\"", "%{count} results for \"%{query}\"", @count, count: @count, query: @query)}
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
  attr(:message, :string, required: true)
  slot(:inner_block)

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
  # View mode toggle
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders a table/card view toggle that syncs all tables sharing the same storage key.

  Place this once at the top of a page, and set `show_toggle={false}` +
  matching `storage_key` on the individual `item_table` components.

  Uses the same localStorage mechanism as `table_default`'s built-in toggle,
  so all tables reading the same key will respect the user's choice.

  ## Attributes

    * `storage_key` — the localStorage key to sync (required, must match the tables)
    * `class` — additional CSS classes

  ## Examples

      <.view_mode_toggle storage_key="catalogue-items" />
      <.item_table cards={true} show_toggle={false} storage_key="catalogue-items" ... />
  """
  attr(:storage_key, :string, required: true)
  attr(:class, :string, default: "")

  def view_mode_toggle(assigns) do
    ~H"""
    <div
      id={"view-toggle-#{@storage_key}"}
      phx-hook="TableCardView"
      data-storage-key={@storage_key}
      class={["hidden md:flex justify-end", @class]}
    >
      <div data-table-view="" class="hidden"></div>
      <div data-card-view="" class="hidden"></div>
      <div class="join">
        <button type="button" data-view-action="card" class="btn btn-sm join-item" title={Gettext.gettext(PhoenixKitWeb.Gettext, "Card view")}>
          <.icon name="hero-squares-2x2" class="w-4 h-4" />
        </button>
        <button type="button" data-view-action="table" class="btn btn-sm join-item" title={Gettext.gettext(PhoenixKitWeb.Gettext, "Table view")}>
          <.icon name="hero-bars-3-bottom-left" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item table
  # ═══════════════════════════════════════════════════════════════════

  @all_columns ~w(name sku base_price price unit status category catalogue manufacturer)a

  @doc """
  Renders a configurable item table with optional card view toggle.

  Columns are opt-in — only the columns you list are shown. Actions (edit, delete,
  restore) are opt-in via their respective attributes.

  ## Attributes

    * `items` — list of items to display (required)
    * `columns` — list of column atoms to show (default: `[:name, :sku, :base_price, :status]`)
      Available: #{inspect(@all_columns)}
    * `cards` — enable card view toggle (default: `false`). When enabled, renders a
      table/card toggle button and shows items as cards on mobile. The card view
      shows the item name as the title, selected columns as key-value fields,
      and action buttons in the card footer.
    * `id` — unique ID for the component (required when `cards` is true, used by
      the JS hook to persist view preference)
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

  ## Examples

      <%!-- Table only --%>
      <.item_table items={@items} columns={[:name, :sku, :base_price]} />

      <%!-- With card view toggle --%>
      <.item_table
        items={@items}
        columns={[:name, :sku, :base_price, :price, :status]}
        cards={true}
        id="catalogue-items"
        markup_percentage={@catalogue.markup_percentage}
        edit_path={&Paths.item_edit/1}
        on_delete="delete_item"
      />
  """
  attr(:items, :list, required: true)
  attr(:columns, :list, default: [:name, :sku, :base_price, :status])
  attr(:cards, :boolean, default: false)
  attr(:show_toggle, :boolean, default: true)
  attr(:id, :string, default: nil)
  attr(:storage_key, :string, default: nil)
  attr(:markup_percentage, :any, default: nil)
  attr(:edit_path, :any, default: nil)
  attr(:on_delete, :string, default: nil)
  attr(:on_restore, :string, default: nil)
  attr(:on_permanent_delete, :string, default: nil)
  attr(:permanent_delete_type, :string, default: "item")
  attr(:catalogue_path, :any, default: nil)
  attr(:variant, :string, default: "default")
  attr(:size, :string, default: "sm")
  attr(:wrapper_class, :string, default: nil)

  def item_table(assigns) do
    assigns =
      assigns
      |> assign(:has_actions, has_actions?(assigns))
      |> assign(:card_columns, Enum.reject(assigns.columns, &(&1 == :name)))

    ~H"""
    <.table_default
      variant={@variant}
      size={@size}
      toggleable={@cards}
      id={@id}
      storage_key={@storage_key}
      items={@items}
      card_fields={&card_fields(&1, @card_columns, @markup_percentage, @catalogue_path)}
    >
      <:card_header :let={item}>
        <.link :if={@edit_path && item.uuid} navigate={safe_call(@edit_path, item.uuid)} class="font-medium text-sm link link-hover">{item.name || "—"}</.link>
        <span :if={!@edit_path || !item.uuid} class="font-medium text-sm">{item.name || "—"}</span>
      </:card_header>
      <.table_default_header>
        <.table_default_row>
          <.table_default_header_cell :for={col <- @columns}>{column_label(col)}</.table_default_header_cell>
          <.table_default_header_cell :if={@has_actions} class="text-right">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</.table_default_header_cell>
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
      <:card_actions :let={item} :if={@has_actions}>
        <.card_action_buttons
          item={item}
          edit_path={@edit_path}
          on_delete={@on_delete}
          on_restore={@on_restore}
          on_permanent_delete={@on_permanent_delete}
          permanent_delete_type={@permanent_delete_type}
        />
      </:card_actions>
    </.table_default>
    """
  end

  # ── Card view helpers ───────────────────────────────────────────

  defp card_fields(item, columns, markup_percentage, catalogue_path) do
    Enum.flat_map(columns, fn col ->
      case card_field_value(item, col, markup_percentage, catalogue_path) do
        nil -> []
        value -> [%{label: column_label(col), value: value}]
      end
    end)
  end

  defp card_field_value(item, :sku, _, _), do: item.sku || "—"
  defp card_field_value(item, :base_price, _, _), do: format_price(item.base_price)
  defp card_field_value(item, :price, markup, _), do: format_price(safe_sale_price(item, markup))
  defp card_field_value(item, :unit, _, _), do: format_unit(item.unit)
  defp card_field_value(item, :status, _, _), do: String.capitalize(item.status || "unknown")
  defp card_field_value(item, :category, _, _), do: safe_assoc_field(item, :category, :name)

  defp card_field_value(item, :catalogue, _, _),
    do: safe_assoc_field(item, :catalogue, :name)

  defp card_field_value(item, :manufacturer, _, _),
    do: safe_assoc_field(item, :manufacturer, :name)

  defp card_field_value(_, col, _, _) do
    Logger.warning("item_table card: unknown column #{inspect(col)}, skipping")
    nil
  end

  attr(:item, :any, required: true)
  attr(:edit_path, :any, default: nil)
  attr(:on_delete, :string, default: nil)
  attr(:on_restore, :string, default: nil)
  attr(:on_permanent_delete, :string, default: nil)
  attr(:permanent_delete_type, :string, default: "item")

  defp card_action_buttons(assigns) do
    ~H"""
    <.link :if={@edit_path && @item.uuid} navigate={safe_call(@edit_path, @item.uuid)} class="btn btn-ghost btn-xs">
      <.icon name="hero-pencil" class="w-3.5 h-3.5" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
    </.link>
    <button :if={@on_delete} phx-click={@on_delete} phx-value-uuid={@item.uuid} class="btn btn-ghost btn-xs text-error">
      <.icon name="hero-trash" class="w-3.5 h-3.5" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
    </button>
    <button :if={@on_restore} phx-click={@on_restore} phx-value-uuid={@item.uuid} class="btn btn-ghost btn-xs text-success">
      <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")}
    </button>
    <button :if={@on_permanent_delete} phx-click={@on_permanent_delete} phx-value-uuid={@item.uuid} phx-value-type={@permanent_delete_type} class="btn btn-ghost btn-xs text-error">
      <.icon name="hero-trash" class="w-3.5 h-3.5" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
    </button>
    """
  end

  # ── Column cells ───────────────────────────────────────────────

  attr(:column, :atom, required: true)
  attr(:item, :any, required: true)
  attr(:markup_percentage, :any, default: nil)
  attr(:catalogue_path, :any, default: nil)

  defp item_cell(%{column: :name} = assigns) do
    ~H"""
    <.table_default_cell class="font-medium">{@item.name || "—"}</.table_default_cell>
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
    <.table_default_cell class="text-sm font-semibold">{format_price(safe_sale_price(@item, @markup_percentage))}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :unit} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm">{format_unit(@item.unit)}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :status} = assigns) do
    ~H"""
    <.table_default_cell><.status_badge status={@item.status || "unknown"} size={:xs} /></.table_default_cell>
    """
  end

  defp item_cell(%{column: :category} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm text-base-content/60">{safe_assoc_field(@item, :category, :name)}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :catalogue} = assigns) do
    assigns =
      assign(
        assigns,
        :catalogue_name,
        safe_assoc_field(assigns.item, :catalogue, :name)
      )

    ~H"""
    <.table_default_cell class="text-sm">
      <.link
        :if={@catalogue_name != "—" && @catalogue_path}
        navigate={safe_call(@catalogue_path, safe_assoc_field(@item, :catalogue, :uuid))}
        class="link link-hover"
      >
        {@catalogue_name}
      </.link>
      <span :if={@catalogue_name == "—" || !@catalogue_path} class="text-base-content/60">—</span>
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :manufacturer} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm text-base-content/60">{safe_assoc_field(@item, :manufacturer, :name)}</.table_default_cell>
    """
  end

  # Catch-all for unknown columns — log warning, render empty cell
  defp item_cell(assigns) do
    Logger.warning("item_table: unknown column #{inspect(assigns.column)}, skipping")

    ~H"""
    <.table_default_cell class="text-sm text-base-content/40">—</.table_default_cell>
    """
  end

  # ── Action cell ────────────────────────────────────────────────

  attr(:item, :any, required: true)
  attr(:edit_path, :any, default: nil)
  attr(:on_delete, :string, default: nil)
  attr(:on_restore, :string, default: nil)
  attr(:on_permanent_delete, :string, default: nil)
  attr(:permanent_delete_type, :string, default: "item")

  defp item_actions(%{item: %{uuid: nil}} = assigns) do
    ~H"""
    <.table_default_cell class="text-right whitespace-nowrap">—</.table_default_cell>
    """
  end

  defp item_actions(assigns) do
    ~H"""
    <.table_default_cell class="text-right whitespace-nowrap">
      <.table_row_menu mode="auto" id={"item-action-#{@item.uuid}"}>
        <.table_row_menu_link :if={@edit_path} navigate={safe_call(@edit_path, @item.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")} />
        <.table_row_menu_divider :if={@edit_path && (@on_delete || @on_restore)} />
        <.table_row_menu_button :if={@on_delete} phx-click={@on_delete} phx-value-uuid={@item.uuid} icon="hero-trash" label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")} variant="error" />
        <.table_row_menu_button :if={@on_restore} phx-click={@on_restore} phx-value-uuid={@item.uuid} icon="hero-arrow-path" label={Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")} variant="success" />
        <.table_row_menu_divider :if={@on_restore && @on_permanent_delete} />
        <.table_row_menu_button :if={@on_permanent_delete} phx-click={@on_permanent_delete} phx-value-uuid={@item.uuid} phx-value-type={@permanent_delete_type} icon="hero-trash" label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")} variant="error" />
      </.table_row_menu>
    </.table_default_cell>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp has_actions?(assigns) do
    assigns[:edit_path] != nil or assigns[:on_delete] != nil or
      assigns[:on_restore] != nil or assigns[:on_permanent_delete] != nil
  end

  defp column_label(:name), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Name")
  defp column_label(:sku), do: Gettext.gettext(PhoenixKitWeb.Gettext, "SKU")
  defp column_label(:base_price), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Base Price")
  defp column_label(:price), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Price")
  defp column_label(:unit), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Unit")
  defp column_label(:status), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Status")
  defp column_label(:category), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Category")
  defp column_label(:catalogue), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue")
  defp column_label(:manufacturer), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturer")
  defp column_label(col), do: col |> to_string() |> String.capitalize()

  defp format_price(nil), do: "—"

  defp format_price(price) do
    Decimal.to_string(price, :normal)
  rescue
    _ -> "—"
  end

  defp format_unit(nil), do: "—"
  defp format_unit("piece"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "pc")
  defp format_unit("set"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "set")
  defp format_unit("pair"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "pair")
  defp format_unit("sheet"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "sheet")
  defp format_unit("m2"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "m²")
  defp format_unit("running_meter"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "rm")
  defp format_unit(other), do: to_string(other)

  # Safe sale price calculation — handles non-Decimal markup gracefully
  defp safe_sale_price(item, markup) do
    Item.sale_price(item, ensure_decimal(markup))
  rescue
    e ->
      Logger.warning("item_table: sale_price error: #{Exception.message(e)}")
      nil
  end

  defp ensure_decimal(nil), do: nil
  defp ensure_decimal(%Decimal{} = d), do: d
  defp ensure_decimal(n) when is_number(n), do: Decimal.new("#{n}")
  defp ensure_decimal(s) when is_binary(s), do: Decimal.new(s)
  defp ensure_decimal(_), do: nil

  # Safe association access — returns "—" if association is nil or not loaded
  defp safe_assoc_field(record, assoc, field) do
    case Map.get(record, assoc) do
      %{__struct__: Ecto.Association.NotLoaded} -> "—"
      nil -> "—"
      assoc_record -> Map.get(assoc_record, field) || "—"
    end
  end

  # Safe function call — catches errors from path functions
  defp safe_call(func, arg) do
    func.(arg)
  rescue
    e ->
      Logger.warning("item_table: path function error: #{Exception.message(e)}")
      "#"
  end

  # Safe nested association access — follows a path of keys, returns nil on any miss
end
