defmodule PhoenixKitCatalogue.Web.TableToolbar do
  @moduledoc """
  Toolbar pieces for the catalogue admin tables: the column-settings modal,
  the sort select+direction control, and an enum filter select. All emit
  plain events handled by `CataloguesLive` against the active scope.
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  alias PhoenixKitCatalogue.Gettext, as: G
  alias PhoenixKitCatalogue.Web.TableConfig

  defp g(s), do: Gettext.gettext(G, s)

  attr(:show, :boolean, required: true)
  attr(:scope, :atom, required: true)
  attr(:selected, :list, required: true)

  # Thin adapter over the core live editor: maps this module's
  # TableConfig catalog into the generic column shape. Event contract
  # (add/remove/reorder/reset/hide) is implemented by the consuming LV.
  def column_settings_modal(assigns) do
    assigns =
      assign(
        assigns,
        :columns,
        for(c <- TableConfig.managed_columns(assigns.scope), do: %{id: c.id, label: c.label})
      )

    ~H"""
    <PhoenixKitWeb.Components.Core.ColumnSettings.column_settings_modal
      id="catalogue-columns-modal"
      show={@show}
      columns={@columns}
      selected={@selected}
    />
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
    <form id={"#{@scope}-sort-controls"} phx-change="set_sort" class="join">
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
    <form id={"filter-form-#{@id}"} phx-change="set_filter" class="contents">
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
