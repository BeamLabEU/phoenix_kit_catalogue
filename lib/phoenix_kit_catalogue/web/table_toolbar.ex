defmodule PhoenixKitCatalogue.Web.TableToolbar do
  @moduledoc """
  Toolbar pieces for the catalogue admin tables: the column-settings modal,
  the sort select+direction control, and an enum filter select. All emit
  plain events handled by `CataloguesLive` against the active scope.
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  alias PhoenixKitCatalogue.Gettext, as: G
  alias PhoenixKitCatalogue.Web.TableConfig

  defp g(s), do: Gettext.gettext(G, s)

  attr(:show, :boolean, required: true)
  attr(:scope, :atom, required: true)
  attr(:selected, :list, required: true)

  # LIVE editor: add / remove / drag apply immediately (the table behind
  # the modal updates as you work), so the footer is just Reset + Close.
  def column_settings_modal(assigns) do
    assigns =
      assigns
      |> assign(:map, TableConfig.column_map(assigns.scope))
      |> assign(:available, TableConfig.managed_columns(assigns.scope))

    assigns =
      assign(assigns, :hidden, Enum.reject(assigns.available, &(&1.id in assigns.selected)))

    ~H"""
    <.modal :if={@show} id="catalogue-columns-modal" show on_close="hide_column_modal">
      <h3 class="text-lg font-semibold mb-3">{g("Columns")}</h3>
      <div class="grid grid-cols-2 gap-4">
        <div>
          <p class="text-xs uppercase text-base-content/50 mb-2">{g("Shown")}</p>
          <ul
            id="catalogue-columns-selected"
            phx-hook="SortableGrid"
            data-sortable="true"
            data-sortable-event="reorder_columns"
            data-sortable-items=".col-item"
            class="space-y-1"
          >
            <li
              :for={id <- @selected}
              :if={@map[id] && @map[id].managed?}
              data-id={id}
              class="col-item flex items-center gap-2 px-2 py-1 rounded bg-base-200"
            >
              <.icon name="hero-bars-3" class="w-4 h-4 pk-drag-handle cursor-grab text-base-content/40" />
              <span class="flex-1 text-sm">{@map[id].label.()}</span>
              <button
                type="button"
                phx-click="remove_column"
                phx-value-column_id={id}
                class="btn btn-ghost btn-xs btn-square text-error cursor-pointer"
                title={g("Remove")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </li>
          </ul>
        </div>
        <div>
          <p class="text-xs uppercase text-base-content/50 mb-2">{g("Available")}</p>
          <ul class="space-y-1">
            <li :for={c <- @hidden}>
              <button
                type="button"
                phx-click="add_column"
                phx-value-column_id={c.id}
                class="flex items-center gap-2 w-full text-left text-sm px-2 py-1 rounded hover:bg-base-200 cursor-pointer transition-colors"
              >
                <.icon name="hero-plus" class="w-4 h-4 text-base-content/40" />
                <span>{c.label.()}</span>
              </button>
            </li>
          </ul>
        </div>
      </div>
      <div class="flex justify-between mt-4">
        <button type="button" phx-click="reset_columns" class="btn btn-ghost btn-sm">
          {g("Reset")}
        </button>
        <button type="button" phx-click="hide_column_modal" class="btn btn-primary btn-sm">
          {g("Close")}
        </button>
      </div>
    </.modal>
    """
  end

  attr(:scope, :atom, required: true)
  attr(:selected, :list, required: true)
  attr(:sort_by, :string, required: true)
  attr(:sort_dir, :atom, required: true)

  attr(:manual_value, :string,
    default: nil,
    doc:
      "sort_by value that means \"manual/drag order\" (e.g. \"position\"). When active, the direction toggle is hidden — direction has no meaning for a user-dragged order."
  )

  def sort_controls(assigns) do
    assigns =
      assigns
      |> assign(:options, TableConfig.sortable_visible(assigns.scope, assigns.selected))
      |> assign(
        :manual_active?,
        assigns.manual_value != nil and assigns.sort_by == assigns.manual_value
      )

    ~H"""
    <form phx-change="set_sort" class="join">
      <select name="sort_by" class="select select-sm join-item">
        <option :for={c <- @options} value={c.id} selected={@sort_by == c.id}>{c.label.()}</option>
      </select>
      <button
        :if={!@manual_active?}
        type="button"
        phx-click="flip_sort_dir"
        class="btn btn-sm btn-ghost join-item"
        title={g("Toggle sort direction")}
      >
        <.icon
          name={if @sort_dir == :asc, do: "hero-chevron-up", else: "hero-chevron-down"}
          class="w-4 h-4"
        />
      </button>
    </form>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)
  attr(:options, :list, required: true)
  attr(:prompt, :string, required: true)

  def enum_filter(assigns) do
    ~H"""
    <form phx-change="set_filter" class="contents">
      <input type="hidden" name="column_id" value={@id} />
      <.select
        name="value"
        id={"filter-#{@id}"}
        value={@value}
        prompt={@prompt}
        options={@options}
        class="select-sm"
        aria-label={@label}
      />
    </form>
    """
  end
end
