defmodule PhoenixKitCatalogue.Web.Components.ItemPickerCardTest do
  @moduledoc """
  Integration test for the picker-owned product card (L026.1): clicking
  the item picker's photo thumbnail opens the card entirely inside the
  component — no host wiring beyond `photo_clickable={true}`. Uses a
  minimal isolated host LiveView.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  # Minimal host that just embeds the picker and counts the upward
  # `{:item_picker_photo_click, …}` messages (the card itself opens
  # without any host handling).
  defmodule HostLive do
    use Phoenix.LiveView

    import PhoenixKitCatalogue.Web.Components, only: [item_picker: 1]

    def mount(_params, session, socket) do
      item =
        case session["item_uuid"] do
          uuid when is_binary(uuid) ->
            PhoenixKitCatalogue.Catalogue.get_item(uuid, preload: [:catalogue])

          _ ->
            nil
        end

      {:ok, assign(socket, item: item, photo_clicks: 0), layout: false}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.item_picker id="host-picker" locale="en" selected_item={@item} photo_clickable={true} />
        <span id="photo-clicks">{@photo_clicks}</span>
      </div>
      """
    end

    def handle_info({:item_picker_photo_click, _id, _item}, socket) do
      {:noreply, update(socket, :photo_clicks, &(&1 + 1))}
    end
  end

  test "clicking the thumbnail opens the product card; closing hides it", %{conn: conn} do
    item =
      fixture_item(%{
        name: "Card Item",
        sku: "CARD-1",
        data: %{"featured_image_uuid" => Ecto.UUID.generate()}
      })

    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"item_uuid" => item.uuid})

    # The card is not open until the thumbnail is clicked.
    refute render(view) =~ ~s(phx-click="card_close")

    # Click the photo preview thumbnail.
    view |> element(~s(button[phx-click="photo_click"])) |> render_click()

    html = render(view)
    assert html =~ "Card Item"
    assert html =~ ~s(phx-click="card_close")
    # A filled field is shown in the card.
    assert html =~ "CARD-1"
    # The upward hook message also fired (opt-in host reaction still works).
    assert has_element?(view, "#photo-clicks", "1")

    # Closing the card hides it again.
    view |> element(~s(button[phx-click="card_close"])) |> render_click()
    refute render(view) =~ ~s(phx-click="card_close")
  end

  test "a forged photo_click with nothing selected is inert", %{conn: conn} do
    # No item in the session, so `selected_item` is nil and the thumbnail
    # button is never rendered — but a client can push the event anyway.
    #
    # The handler used to fire `{:item_picker_photo_click, id, nil}` upward
    # before `open_card/2` ignored the nil, so a host matching on `%Item{}`
    # (the shape the moduledoc promises) crashed. Nothing should happen at all.
    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{})

    refute has_element?(view, ~s(button[phx-click="photo_click"]))

    # Targeted at the LiveComponent, not the host — the handler under test is
    # the component's, and that is also where a forged client event would go.
    view |> with_target("#host-picker") |> render_click("photo_click", %{})

    assert has_element?(view, "#photo-clicks", "0")
    refute render(view) =~ ~s(phx-click="card_close")
    assert Process.alive?(view.pid)
  end
end
