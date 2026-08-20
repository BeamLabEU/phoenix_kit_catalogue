defmodule PhoenixKitCatalogue.Web.Components.CrmLinkPanel do
  @moduledoc """
  The "CRM party" card shared by the supplier and manufacturer forms.

  Renders one of three states:

    * **CRM not installed** — nothing at all. The catalogue must look and
      behave exactly as it did on a standalone install.
    * **unlinked** — a company picker plus a Link button.
    * **linked** — who it projects, a Refresh action, and an Unlink action,
      with the identity fields upstairs turned read-only by the caller.

  The panel only renders on an existing record: linking needs a persisted
  row to stamp, and offering the control while creating one would promise
  something the save path cannot keep.

  Events are handled by the parent LiveView (`crm_link`, `crm_unlink`,
  `crm_refresh`) because the actions differ per record type; the markup and
  the rules for which state is shown live here so the two forms cannot
  drift apart.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr(:record, :map, required: true, doc: "the persisted supplier or manufacturer")
  attr(:kind, :atom, required: true, values: [:supplier, :manufacturer])
  attr(:available, :boolean, required: true, doc: "CRM module present")
  attr(:candidates, :list, default: [], doc: "{name, uuid} pairs offered for linking")
  attr(:party, :map, default: nil, doc: "the resolved party when linked, else nil")

  def crm_link_panel(assigns) do
    ~H"""
    <div :if={@available and @record && @record.uuid} class="flex flex-col gap-4">
      <div class="divider my-0"></div>

      <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
        <.icon name="hero-building-office-2" class="h-4 w-4" />
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "CRM Company")}
      </h2>

      <div :if={@record.crm_company_uuid} class="flex flex-col gap-3">
        <div class="alert alert-info py-2">
          <.icon name="hero-link" class="h-4 w-4 shrink-0" />
          <span class="text-sm">
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "Identity is managed in CRM. Name, website and contact info are read-only here."
            )}
          </span>
        </div>

        <div :if={@party} class="text-sm text-base-content/70">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Linked to")}
          <span class="font-medium text-base-content">{@party.name}</span>
        </div>

        <div :if={is_nil(@party)} class="text-sm text-warning">
          {Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "The linked CRM company could not be found. Unlink to edit locally again."
          )}
        </div>

        <div class="flex flex-wrap gap-2">
          <.button
            type="button"
            variant="ghost"
            phx-click="crm_refresh"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Refreshing...")}
          >
            <.icon name="hero-arrow-path" class="h-4 w-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Refresh from CRM")}
          </.button>
          <.button type="button" variant="ghost" phx-click="crm_unlink">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unlink")}
          </.button>
        </div>
      </div>

      <div :if={is_nil(@record.crm_company_uuid)} class="flex flex-col gap-3">
        <p class="text-sm text-base-content/50 -mt-2">
          {link_hint(@kind)}
        </p>

        <div :if={@candidates == []} class="text-sm text-base-content/50">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No CRM companies yet.")}
        </div>

        <form :if={@candidates != []} phx-submit="crm_link" class="flex flex-wrap gap-2 items-end">
          <select name="company_uuid" class="select select-bordered grow min-w-56">
            <option value="">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select a CRM company...")}
            </option>
            <option :for={{name, uuid} <- @candidates} value={uuid}>{name}</option>
          </select>
          <.button
            type="submit"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Linking...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Link")}
          </.button>
        </form>
      </div>
    </div>
    """
  end

  @doc """
  Turns a `CrmLink` error into a flash message.

  Lives here rather than in each form because both need the identical
  mapping, and a copy per LiveView is how the two would quietly diverge.
  """
  @spec error_message(term()) :: String.t()
  def error_message(:crm_unavailable),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "The CRM module is not available.")

  def error_message(reason) when reason in [:company_not_found, :party_not_found],
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "That CRM company no longer exists.")

  def error_message(:not_linked),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "This record is not linked to CRM.")

  def error_message(%Ecto.Changeset{} = changeset) do
    if Enum.any?(changeset.errors, fn {field, _} -> field == :crm_company_uuid end) do
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "That CRM company is already linked to another record."
      )
    else
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not save the change.")
    end
  end

  def error_message(_other),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not save the change.")

  defp link_hint(:supplier) do
    Gettext.gettext(
      PhoenixKitCatalogue.Gettext,
      "Link this supplier to the CRM company it represents. The company gains the supplier role and its details are copied here."
    )
  end

  defp link_hint(:manufacturer) do
    Gettext.gettext(
      PhoenixKitCatalogue.Gettext,
      "Link this manufacturer to the CRM company it represents. Link only a real company — a brand you never deal with belongs in the catalogue alone."
    )
  end
end
