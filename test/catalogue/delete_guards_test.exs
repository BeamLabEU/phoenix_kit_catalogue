defmodule PhoenixKitCatalogue.Catalogue.DeleteGuardsTest do
  @moduledoc """
  One boot task registers both of the catalogue's entities delete guards. On
  tim-dev and max-dev the two used to register from separate tasks, raced,
  and the attribute-set guard went missing, so every set delete failed closed
  with `:no_delete_guard`.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue.DeleteGuards

  setup do
    PhoenixKit.Settings.update_setting("entities_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
    :ok
  end

  test "register/0 leaves both owners with a delete guard" do
    assert DeleteGuards.register() == :ok

    for owner <- ["catalogue", "catalogue_supplier"] do
      blueprint = %{
        uuid: Ecto.UUID.generate(),
        name: "guard-check",
        status: "published",
        settings: %{"managed_by" => owner}
      }

      refute PhoenixKitEntities.Managed.validate_delete(blueprint, on_behalf_of: owner) ==
               {:error, :no_delete_guard},
             "no delete guard registered for #{owner}"
    end
  end

  test "the boot task is a one-shot child" do
    assert %{restart: :temporary, start: {Task, :start_link, [_fun]}} =
             DeleteGuards.child_spec([])
  end
end
