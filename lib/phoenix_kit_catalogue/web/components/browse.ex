defmodule PhoenixKitCatalogue.Web.Components.Browse do
  @moduledoc """
  Embeddable, selection-agnostic building blocks for browsing catalogue
  items — the pieces `ItemSelectorModal` is assembled from, exposed so a
  host LiveView can compose its own browse surface (a storefront section,
  a picker, a read-only category wall) without copying markup.

  Everything here is a pure function component: state in, events out. Each
  interactive component takes a `target` (`phx-target`) so it works inside
  a LiveComponent as well as straight in a LiveView — leave it `nil` and
  events go to the host LV. Event names are fixed (documented per
  component) so one `handle_event/3` vocabulary serves every embedding.

  The data these render is a *presented item* — a plain map produced by
  `present_items/2`, which resolves translations and the featured-photo URL
  once per fetch rather than on every render:

      items
      |> Browse.present_items(locale)
      # => [%{uuid: "…", name: "…", sku: "…", price: %Decimal{}|nil,
      #       unit: "piece", photo_url: "/…/medium/…"|nil,
      #       manufacturer: "…"|nil, default_qty: %Decimal{}}]

  Pair them with `PhoenixKitCatalogue.Catalogue.BrowseState` for the
  fetch/paging state machine; the moduledoc there shows the loop.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitCatalogue.Catalogue.Translations

  @photo_variant "medium"

  @doc """
  Denormalizes schema items into presented maps: translated name, signed
  featured-photo URL, and the default quantity a picker should start at
  (the item's `default_value` when set, else 1).

  Runs once per fetched page — never call translation or URL helpers from
  a template; a quantity keystroke re-renders every card.
  """
  def present_items(items, locale) do
    Enum.map(items, fn item ->
      translated = Translations.get_translation(item, locale)

      %{
        uuid: to_string(item.uuid),
        name: translated["name"] || item.name,
        sku: item.sku,
        price: item.base_price,
        unit: item.unit,
        manufacturer: item.manufacturer_name || item.manufacturer_name_snapshot,
        photo_url: featured_photo_url(item),
        default_qty: default_qty(item)
      }
    end)
  end

  @doc """
  Signed URL for an item's featured photo (`#{@photo_variant}` variant), or
  nil. Signing is pure computation — no Storage roundtrip — so this is safe
  per item; it lives here so every surface resolves photos one way.
  """
  def featured_photo_url(item) do
    case item.data["featured_image_uuid"] do
      uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, @photo_variant)
      _ -> nil
    end
  end

  defp default_qty(%{default_value: %Decimal{} = d}) do
    if Decimal.compare(d, 0) == :gt, do: d, else: Decimal.new(1)
  end

  defp default_qty(_), do: Decimal.new(1)

  @doc """
  Horizontally scrollable category filter chips: "All" plus one per
  category. Dispatches `browse_category` with `phx-value-uuid` ("" for All).
  """
  attr(:id, :string, required: true)
  attr(:categories, :list, required: true, doc: "[%{uuid:, name:}]")
  attr(:active_uuid, :string, default: nil)
  attr(:target, :any, default: nil)

  def category_chips(assigns) do
    ~H"""
    <div id={@id} class="flex gap-1.5 overflow-x-auto pb-1" role="group" aria-label={gettext("Categories")}>
      <button
        type="button"
        class={["btn btn-xs rounded-full", if(@active_uuid, do: "btn-ghost", else: "btn-primary")]}
        phx-click="browse_category"
        phx-value-uuid=""
        phx-target={@target}
      >
        {gettext("All")}
      </button>
      <button
        :for={category <- @categories}
        type="button"
        class={[
          "btn btn-xs rounded-full whitespace-nowrap",
          if(@active_uuid == to_string(category.uuid), do: "btn-primary", else: "btn-ghost")
        ]}
        phx-click="browse_category"
        phx-value-uuid={category.uuid}
        phx-target={@target}
      >
        {category.name}
      </button>
    </div>
    """
  end

  @doc """
  The responsive card grid. Cards come in through the default slot so the
  caller decides what a card is — this component owns only the layout.
  """
  attr(:id, :string, required: true)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def item_grid(assigns) do
    ~H"""
    <div id={@id} class={["grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One product card: photo-forward (square, `object-cover`, lazy), then
  name / sku / price. Selection chrome is NOT built in — the picker layers
  it through the `:footer` slot and the `selected` ring, so a plain browse
  embedding renders the same card with neither.

  Dispatches `card_click` with `phx-value-uuid` when `clickable`.
  """
  attr(:id, :string, required: true)
  attr(:item, :map, required: true, doc: "a presented item (see present_items/2)")
  attr(:selected, :boolean, default: false)
  attr(:clickable, :boolean, default: true)
  attr(:show_price, :boolean, default: true)
  attr(:show_sku, :boolean, default: true)
  attr(:target, :any, default: nil)
  slot(:footer)

  def item_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "card bg-base-100 border transition-shadow overflow-hidden",
        if(@selected,
          do: "border-primary ring-2 ring-primary/40",
          else: "border-base-300 hover:shadow-md"
        )
      ]}
      data-selected={to_string(@selected)}
    >
      <button
        type="button"
        class="text-left w-full cursor-pointer disabled:cursor-default"
        phx-click={@clickable && "card_click"}
        phx-value-uuid={@item.uuid}
        phx-target={@target}
        disabled={!@clickable}
        aria-pressed={@selected}
        aria-label={@item.name}
      >
        <figure class="relative aspect-square bg-base-200">
          <img
            :if={@item.photo_url}
            src={@item.photo_url}
            alt={@item.name}
            class="w-full h-full object-cover"
            loading="lazy"
            decoding="async"
          />
          <%!-- No photo: a deliberate tile (SKU initial), not a broken image. --%>
          <div
            :if={!@item.photo_url}
            class="w-full h-full flex flex-col items-center justify-center text-base-content/40"
          >
            <span class="text-4xl font-bold">{String.first(@item.sku || @item.name || "?")}</span>
            <span :if={@item.sku} class="font-mono text-xs mt-1">{@item.sku}</span>
          </div>
          <span
            :if={@selected}
            class="absolute top-2 right-2 badge badge-primary badge-sm gap-1"
            aria-hidden="true"
          >
            <.icon name="hero-check" class="w-3 h-3" />
          </span>
        </figure>
        <div class="card-body p-3 gap-0.5">
          <span class="font-medium text-sm leading-snug line-clamp-2" title={@item.name}>
            {@item.name}
          </span>
          <span :if={@show_sku && @item.sku} class="font-mono text-xs text-base-content/60">
            {@item.sku}
          </span>
          <span :if={@show_price && @item.price} class="text-sm font-semibold">
            {format_price(@item.price)}
            <span :if={@item.unit} class="text-xs font-normal text-base-content/60">
              / {@item.unit}
            </span>
          </span>
        </div>
      </button>
      {render_slot(@footer)}
    </div>
    """
  end

  @doc """
  Quantity stepper: minus / text input / plus. The input commits on blur or
  Enter (`qty_commit` with `%{"uuid" =>, "value" =>}`) — never on keystroke,
  so typing "2." on the way to "2.5" is not fought. The buttons dispatch
  `qty_dec` / `qty_inc` immediately.

  Integer mode is `precision: 0` (the default); a decimal item is the same
  component with `precision > 0` and a `unit` suffix — no redesign, which
  is the point. All limits are re-enforced server-side; these attrs only
  shape the keyboard.
  """
  attr(:id, :string, required: true)
  attr(:uuid, :string, required: true)
  attr(:qty, :string, required: true, doc: "display string, already formatted")
  attr(:unit, :string, default: nil)
  attr(:precision, :integer, default: 0)
  attr(:target, :any, default: nil)
  attr(:size, :string, default: "sm", values: ~w(xs sm))

  def qty_stepper(assigns) do
    ~H"""
    <div id={@id} class="join" role="group" aria-label={gettext("Quantity")}>
      <button
        type="button"
        class={["btn join-item", btn_size(@size)]}
        phx-click="qty_dec"
        phx-value-uuid={@uuid}
        phx-target={@target}
        aria-label={gettext("Decrease quantity")}
      >
        −
      </button>
      <%!-- A form so Enter commits; phx-blur commits on focus loss. One
           form per stepper — ids stay unique by construction. --%>
      <form
        id={"#{@id}-form"}
        class="join-item"
        phx-submit="qty_commit"
        phx-target={@target}
      >
        <input type="hidden" name="uuid" value={@uuid} />
        <input
          id={"#{@id}-input"}
          type="text"
          name="value"
          value={@qty}
          inputmode={if @precision > 0, do: "decimal", else: "numeric"}
          class={["input join-item w-14 text-center px-1", input_size(@size)]}
          phx-blur="qty_commit"
          phx-value-uuid={@uuid}
          phx-target={@target}
          aria-label={gettext("Quantity")}
        />
      </form>
      <span
        :if={@unit}
        class={["btn join-item pointer-events-none font-normal text-base-content/60", btn_size(@size)]}
        aria-hidden="true"
      >
        {@unit}
      </span>
      <button
        type="button"
        class={["btn join-item", btn_size(@size)]}
        phx-click="qty_inc"
        phx-value-uuid={@uuid}
        phx-target={@target}
        aria-label={gettext("Increase quantity")}
      >
        +
      </button>
    </div>
    """
  end

  defp btn_size("xs"), do: "btn-xs"
  defp btn_size(_), do: "btn-sm"
  defp input_size("xs"), do: "input-xs"
  defp input_size(_), do: "input-sm"

  @doc """
  Placeholder cards with the exact geometry of `item_card/1`, so the grid
  does not reflow when real items arrive.
  """
  attr(:id, :string, required: true)
  attr(:count, :integer, default: 8)

  def grid_skeleton(assigns) do
    ~H"""
    <div :for={i <- 1..@count} id={"#{@id}-#{i}"} class="card border border-base-300 overflow-hidden">
      <div class="skeleton aspect-square rounded-none"></div>
      <div class="card-body p-3 gap-2">
        <div class="skeleton h-4 w-3/4"></div>
        <div class="skeleton h-3 w-1/3"></div>
      </div>
    </div>
    """
  end

  @doc """
  Formats a Decimal price for the card/tray. Bare number, no currency
  symbol — the same convention as the module's item table (`format_price`
  in `Web.Components`): which currency a price is in is host business the
  catalogue has never decided.
  """
  def format_price(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 2), :normal)
  def format_price(_), do: nil
end
