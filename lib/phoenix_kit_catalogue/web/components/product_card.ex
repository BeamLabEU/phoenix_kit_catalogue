defmodule PhoenixKitCatalogue.Web.Components.ProductCard do
  @moduledoc """
  A read-only product card for a catalogue `%Item{}`, opened from the
  `ItemPicker` thumbnail (the `{:item_picker_photo_click, …}` hook).

  It is a **pure function component** — `product_card/1` renders a
  `<.modal>` containing a "one expanded" image gallery (the main image
  large, a thumbnail strip of the item's other images below it,
  switching on click) plus the item's filled scalar fields (SKU, price,
  unit, description, metadata); empty fields are omitted.

  Image resolution and field extraction (the DB-backed work) live in the
  public helpers `resolve_images/1`, `resolve_name/2`, and `build_fields/2`
  so the component itself stays render-only and testable without a
  database. The owning `ItemPicker` calls the helpers when the thumbnail
  is clicked, stashes the results, and renders the component; all of the
  card's events (`card_select_image`, close) target the picker via
  `@target`, so the whole card lives inside the picker with no host
  wiring.

  ## Usage (from a LiveComponent that owns the state)

      <ProductCard.product_card
        id={@id}
        show={@card_open}
        item_name={@card_name}
        images={@card_images}
        current_image={@card_current}
        fields={@card_fields}
        target={@myself}
        on_close="card_close"
      />
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitCatalogue.{Catalogue, Metadata}
  alias PhoenixKitCatalogue.Schemas.Item

  # ── Render ───────────────────────────────────────────────────────

  @doc """
  Renders the product card modal. Pure: every DB-backed value
  (`images`, `fields`, `item_name`) is resolved by the caller and passed
  in.

  Attrs:

    * `:id` (required) — used to derive the modal's DOM id.
    * `:show` (required) — whether the modal is open.
    * `:target` (required) — the `@myself` of the LiveComponent that
      handles `card_select_image` / the close event (the `ItemPicker`).
    * `:item_name` — card title.
    * `:images` — ordered list of `%{uuid, name}` (main image first).
    * `:current_image` — UUID of the image shown large.
    * `:fields` — list of `{label, value}` for the already-filtered,
      non-empty fields.
    * `:on_close` — event pushed to `@target` on close (default
      `"card_close"`).
  """
  attr(:id, :string, required: true)
  attr(:show, :boolean, required: true)
  attr(:target, :any, required: true)
  attr(:item_name, :string, default: nil)
  attr(:images, :list, default: [])
  attr(:current_image, :string, default: nil)
  attr(:fields, :list, default: [])
  attr(:on_close, :string, default: "card_close")

  def product_card(assigns) do
    ~H"""
    <.modal show={@show} id={"#{@id}-card"} on_close={@on_close} max_width="3xl">
      <:title>{@item_name || Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item")}</:title>

      <div class="flex flex-col gap-4">
        <%!-- Main (expanded) image --%>
        <img
          :if={@current_image}
          src={URLSigner.signed_url(@current_image, "medium")}
          alt={@item_name}
          class="w-full max-h-[50vh] object-contain rounded-lg bg-base-200"
        />

        <%!-- Thumbnail strip — only when there is more than one image.
             Scrolls horizontally on narrow screens. --%>
        <div :if={length(@images) > 1} class="flex gap-2 overflow-x-auto pb-1">
          <button
            :for={img <- @images}
            type="button"
            phx-click="card_select_image"
            phx-value-uuid={img.uuid}
            phx-target={@target}
            class="shrink-0"
            aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Show this image")}
            aria-pressed={to_string(img.uuid == @current_image)}
          >
            <img
              src={URLSigner.signed_url(img.uuid, "thumbnail")}
              alt={img.name || ""}
              class={[
                "w-16 h-16 object-cover rounded border-2",
                (img.uuid == @current_image && "border-primary") || "border-base-300"
              ]}
            />
          </button>
        </div>

        <%!-- Filled fields (empty ones already dropped by build_fields/2) --%>
        <dl
          :if={@fields != []}
          class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3 border-t border-base-200 pt-4"
        >
          <div :for={{label, value} <- @fields} class="min-w-0">
            <dt class="text-xs font-medium text-base-content/50">{label}</dt>
            <dd class="text-sm text-base-content break-words whitespace-pre-line">{value}</dd>
          </div>
        </dl>
      </div>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click={@on_close} phx-target={@target}>
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
        </button>
      </:actions>
    </.modal>
    """
  end

  # ── Resolution helpers (DB-backed; called by the picker on click) ─

  @doc """
  Resolves the ordered gallery images for an item: the main
  (`featured_image_uuid`) first, then the remaining image files in the
  item's `files_folder_uuid`, de-duplicated. Returns `%{uuid, name}`
  maps. Nil/blank-safe and rescued — a missing folder or a Storage
  hiccup degrades to just the main image (or `[]` if there is none).
  """
  @spec resolve_images(Item.t() | term()) :: [%{uuid: String.t(), name: String.t() | nil}]
  def resolve_images(%Item{data: data}) when is_map(data) do
    featured = read_uuid(data, "featured_image_uuid")
    folder_images = list_folder_images(read_uuid(data, "files_folder_uuid"))

    case featured do
      nil -> folder_images
      uuid -> [%{uuid: uuid, name: nil} | Enum.reject(folder_images, &(&1.uuid == uuid))]
    end
  end

  def resolve_images(_), do: []

  @doc "Resolves the item's display name for the given locale (translation, then bare name)."
  @spec resolve_name(Item.t() | term(), String.t()) :: String.t() | nil
  def resolve_name(%Item{} = item, locale) do
    translation = safe_translation(item, locale)

    Map.get(translation, "_name") ||
      Map.get(translation, "name") ||
      item.name
  end

  def resolve_name(_, _), do: nil

  @doc """
  Builds the ordered `{label, value}` list of the item's filled,
  user-facing scalar fields — SKU, price, unit, description, then
  metadata. Empty values are dropped, so the card only shows what is set.
  """
  @spec build_fields(Item.t() | term(), String.t()) :: [{String.t(), String.t()}]
  def build_fields(%Item{} = item, locale) do
    [
      {gettext("SKU"), item.sku},
      {gettext("Price"), format_price(item)},
      {gettext("Unit"), unit_value(item)},
      {gettext("Description"), resolve_description(item, locale)}
    ]
    |> Enum.concat(metadata_fields(item))
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
  end

  def build_fields(_, _), do: []

  # ── Internals ─────────────────────────────────────────────────────

  defp list_folder_images(nil), do: []

  defp list_folder_images(folder_uuid) when is_binary(folder_uuid) do
    {files, _total} =
      Storage.list_files_in_scope(nil, folder_uuid: folder_uuid, file_type: "image", per_page: 50)

    Enum.map(files, &%{uuid: &1.uuid, name: &1.original_file_name})
  rescue
    _ -> []
  end

  defp format_price(%Item{} = item) do
    case Catalogue.item_pricing(item).final_price do
      %Decimal{} = price -> Decimal.to_string(price, :normal)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp unit_value(%Item{unit: unit}) do
    case Item.unit_label(unit) do
      "" -> nil
      label -> label
    end
  end

  defp resolve_description(%Item{} = item, locale) do
    translation = safe_translation(item, locale)

    Map.get(translation, "_description") ||
      Map.get(translation, "description") ||
      item.description
  end

  defp metadata_fields(%Item{} = item) do
    state = Metadata.build_state(:item, item)

    Enum.map(state.attached, fn key ->
      label =
        case Metadata.definition(:item, key) do
          %{label: label} -> label
          _ -> key
        end

      {label, Map.get(state.values, key)}
    end)
  end

  defp safe_translation(record, locale) do
    Catalogue.get_translation(record, locale)
  rescue
    _ -> %{}
  end

  defp read_uuid(data, key) when is_map(data) do
    case Map.get(data, key) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  defp read_uuid(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp gettext(msgid), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid)
end
