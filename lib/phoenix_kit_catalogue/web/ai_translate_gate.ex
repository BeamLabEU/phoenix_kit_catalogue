defmodule PhoenixKitCatalogue.Web.AITranslateGate do
  @moduledoc """
  Re-checks the `catalogue` permission before an AI-translate modal event
  reaches its handler.

  `PhoenixKitAI.Components.AITranslate.Embed` handles the modal's events in
  a `:handle_event` lifecycle hook and has no authorization callback, so
  `ai_translate_lang` would enqueue a translation for whoever can still send
  the event. Declared with `on_mount(PhoenixKitCatalogue.Web.AITranslateGate)`
  BEFORE `use ...AITranslate.Embed` (hooks run in the order they attach),
  this hook halts those events with a refusal when the socket's CURRENT
  scope no longer holds the key — the scope core swaps in when a role loses
  a grant mid-session.
  """

  use Gettext, backend: PhoenixKitCatalogue.Gettext

  alias PhoenixKit.Users.Auth.Scope

  @events ~w(ai_translate_lang ai_toggle_modal ai_select_endpoint ai_select_prompt
             ai_select_scope ai_generate_prompt)

  @doc "The modal events this gate re-checks."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :catalogue_ai_translate_gate, :handle_event, &gate/3)}
  end

  @doc false
  def gate(event, _params, socket) when event in @events do
    if Scope.can?(socket.assigns[:phoenix_kit_current_scope], PhoenixKitCatalogue.module_key()) do
      {:cont, socket}
    else
      {:halt,
       Phoenix.LiveView.put_flash(
         socket,
         :error,
         gettext("You do not have permission to translate catalogue content.")
       )}
    end
  end

  def gate(_event, _params, socket), do: {:cont, socket}
end
