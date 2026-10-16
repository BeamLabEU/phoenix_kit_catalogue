defmodule PhoenixKitCatalogue.Web.Components.DependenciesPanel do
  @moduledoc """
  The item form's Dependencies tab: the staged rows of a
  `PhoenixKitCatalogue.Web.DependencyDraft` and the two ways to add one —
  a catalogue or category from the place tree, or an item from the item
  picker.

  Rendered OUTSIDE the item form: the rows are a small form of their own
  (`dependency_change`), and the pickers bring their own inputs. Nothing
  here writes — the item's Save does (`ItemFormLive`). The host
  LiveView handles `dependency_open_places`, `dependency_change`,
  `dependency_remove` and `dependency_move`, plus the pickers' messages
  `{TreePicker, "dependency-place-picker", id}` and
  `{:item_picker_select, "dependency-item-picker", item}`.

  Internal catalogues are offered here like any other: this is an admin
  page, and back-office stock is exactly what a dependency points at.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitCatalogue.Web.Components, only: [item_picker: 1]

  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.ItemDependency
  alias PhoenixKitCatalogue.Web.DependencyDraft
  alias PhoenixKitWeb.Components.TreePicker

  attr(:draft, DependencyDraft, required: true)
  attr(:item_uuid, :string, default: nil)
  attr(:place_tree, :list, default: nil, doc: "The open place picker's tree; nil while closed.")
  attr(:class, :any, default: nil)

  def dependencies_panel(assigns) do
    ~H"""
    <div id="item-dependencies" class={["card bg-base-100 shadow-lg", @class]}>
      <div class="card-body flex flex-col gap-4">
        <p class="text-sm text-base-content/60">
          {Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "What this item needs from other catalogues, categories or items, and how many. It is for the people using the catalogue: nothing is calculated from it."
          )}
        </p>

        <p :if={@draft.rows == []} id="dependencies-empty" class="text-sm text-base-content/50">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No dependencies yet.")}
        </p>

        <form
          :if={@draft.rows != []}
          id="dependency-rows-form"
          phx-change="dependency_change"
          phx-submit="dependency_change"
          class="flex flex-col divide-y divide-base-200"
        >
          <div
            :for={{row, index} <- Enum.with_index(@draft.rows)}
            id={"dependency-row-#{row.key}"}
            data-dependency-kind={row.kind}
            class="flex flex-wrap items-start gap-3 py-3"
          >
            <.icon name={kind_icon(row.kind)} class="w-5 h-5 mt-2 shrink-0 text-base-content/60" />

            <div class="flex-1 min-w-48 flex flex-col gap-0.5 pt-1.5">
              <div class="flex items-center gap-2 min-w-0">
                <.link
                  navigate={target_path(row)}
                  class="link link-hover font-medium truncate"
                >
                  {row.name || "—"}
                </.link>
                <span class="badge badge-ghost badge-xs shrink-0">{kind_label(row.kind)}</span>
                <span :if={row.internal?} class="badge badge-ghost badge-xs shrink-0">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Internal")}
                </span>
                <span :if={row.trashed?} class="badge badge-warning badge-xs shrink-0">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "In trash")}
                </span>
              </div>
              <span :if={row.place} class="text-xs text-base-content/50 truncate">{row.place}</span>
            </div>

            <label class="flex flex-col gap-1 w-28">
              <span class="text-xs text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Quantity")}
              </span>
              <input
                type="text"
                inputmode="decimal"
                name={"dependencies[#{row.key}][quantity]"}
                value={row.quantity}
                phx-debounce="300"
                class={["input input-sm w-full", row.error == "quantity" && "input-error"]}
              />
            </label>

            <label class="flex flex-col gap-1 flex-1 min-w-48">
              <span class="text-xs text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Note")}
              </span>
              <input
                type="text"
                name={"dependencies[#{row.key}][note]"}
                value={row.note}
                maxlength={ItemDependency.max_note_length()}
                phx-debounce="300"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., pick by wood type")}
                class={["input input-sm w-full", row.error == "note" && "input-error"]}
              />
            </label>

            <div class="flex items-center gap-1 pt-6">
              <button
                type="button"
                phx-click="dependency_move"
                phx-value-key={row.key}
                phx-value-direction="up"
                disabled={index == 0}
                class="btn btn-ghost btn-xs btn-square"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move up")}
              >
                <.icon name="hero-arrow-up" class="w-4 h-4" />
              </button>
              <button
                type="button"
                phx-click="dependency_move"
                phx-value-key={row.key}
                phx-value-direction="down"
                disabled={index == length(@draft.rows) - 1}
                class="btn btn-ghost btn-xs btn-square"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move down")}
              >
                <.icon name="hero-arrow-down" class="w-4 h-4" />
              </button>
              <button
                type="button"
                phx-click="dependency_remove"
                phx-value-key={row.key}
                class="btn btn-ghost btn-xs btn-square text-error"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <p :if={row.error} class="basis-full text-xs text-error pl-8">
              {row_error_message(row.error)}
            </p>
          </div>
        </form>

        <div class="divider my-0"></div>

        <div class="flex flex-col gap-3">
          <div class="flex flex-wrap items-center gap-3">
            <button
              type="button"
              id="dependency-add-place"
              phx-click="dependency_open_places"
              class={["btn btn-sm", if(@place_tree, do: "btn-active", else: "btn-outline")]}
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add a catalogue or category")}
            </button>

            <div class="flex-1 min-w-64">
              <.item_picker
                id="dependency-item-picker"
                include_internal
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add an item: search by name or SKU…")}
                excluded_uuids={List.wrap(@item_uuid)}
                show_sku
              />
            </div>
          </div>

          <div :if={@place_tree} id="dependency-place-picker-panel" class="border border-base-300 rounded-box p-3">
            <.live_component
              module={TreePicker}
              id="dependency-place-picker"
              tree={@place_tree}
              value={nil}
              pickable={[:catalogue, :category]}
              path_skip={[:folder]}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp kind_icon(:catalogue), do: "hero-rectangle-stack"
  defp kind_icon(:category), do: "hero-folder"
  defp kind_icon(:item), do: "hero-cube"

  defp kind_label(:catalogue), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue")
  defp kind_label(:category), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")
  defp kind_label(:item), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item")

  defp target_path(%{kind: :catalogue, uuid: uuid}), do: Paths.catalogue_detail(uuid)

  defp target_path(%{kind: :category, uuid: uuid, catalogue_uuid: catalogue_uuid})
       when is_binary(catalogue_uuid),
       do: Paths.category_browse(catalogue_uuid, uuid)

  defp target_path(%{kind: :item, uuid: uuid}), do: Paths.item_edit(uuid)
  defp target_path(_row), do: nil

  defp row_error_message("note"),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "The note is too long (%{max} characters at most).",
        max: ItemDependency.max_note_length()
      )

  defp row_error_message(_quantity),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Enter a quantity above zero, with at most four decimal places."
      )
end
