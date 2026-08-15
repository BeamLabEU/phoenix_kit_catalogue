defmodule PhoenixKitCatalogue.Web.Components.ItemPickerReopenTest do
  @moduledoc """
  L027: reopening the picker for a *pre-selected* item must show the same
  non-empty replacement list a freshly-selected item shows — not "No items
  found". Uses a fresh LiveView mount (no prior query_change in this
  process) to reproduce the post-reload state: `selected_item` set, but
  `options` never searched yet.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  defmodule HostLive do
    use Phoenix.LiveView

    import PhoenixKitCatalogue.Web.Components, only: [item_picker: 1]

    def mount(_params, session, socket) do
      item = PhoenixKitCatalogue.Catalogue.get_item(session["item_uuid"], preload: [:catalogue])
      {:ok, assign(socket, item: item), layout: false}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.item_picker id="host-picker" locale="en" selected_item={@item} />
      </div>
      """
    end

    def handle_info({:item_picker_select, _id, _item}, socket), do: {:noreply, socket}
    def handle_info({:item_picker_clear, _id}, socket), do: {:noreply, socket}
  end

  test "focusing a picker mounted with an already-selected item opens a non-empty list", %{
    conn: conn
  } do
    cat = fixture_catalogue(%{name: "Reopen Cat"})
    item = fixture_item(%{name: "Preselected Item", catalogue_uuid: cat.uuid})
    _sibling = fixture_item(%{name: "Sibling Item", catalogue_uuid: cat.uuid})

    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"item_uuid" => item.uuid})

    # Input already mirrors the selected item's name — same as the "just
    # selected" state.
    assert has_element?(view, "#host-picker-input[value='Preselected Item']")

    # Nothing has been searched yet in this process — reproduces the
    # post-reload mount, unlike a live selection where a prior
    # query_change already populated `options`.
    view |> element("#host-picker-input") |> render_focus()

    html = render(view)
    refute html =~ "No items found"
    assert html =~ ~s(id="host-picker-listbox")
    assert html =~ "Preselected Item"
  end
end
