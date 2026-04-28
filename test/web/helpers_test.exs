defmodule PhoenixKitCatalogue.Web.HelpersTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Web.Helpers

  describe "status_label/1" do
    test "translates known statuses" do
      assert Helpers.status_label("active") == "Active"
      assert Helpers.status_label("inactive") == "Inactive"
      assert Helpers.status_label("archived") == "Archived"
      assert Helpers.status_label("deleted") == "Deleted"
      assert Helpers.status_label("discontinued") == "Discontinued"
    end

    test "returns the raw key for unknown binaries" do
      # Pinning the do-not-ask rule: never `String.capitalize/1` on
      # translated text. Adding a literal clause to `status_label/1`
      # is the right fix when a new status atom is introduced.
      assert Helpers.status_label("mystery") == "mystery"
    end

    test "returns a translated 'Unknown' for nil / non-binary" do
      assert Helpers.status_label(nil) == "Unknown"
      assert Helpers.status_label(:atom) == "Unknown"
    end
  end

  describe "actor_opts/1" do
    test "returns [actor_uuid: uuid] when current_user is set" do
      socket = %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_user: %{uuid: "abc"}}}
      assert Helpers.actor_opts(socket) == [actor_uuid: "abc"]
    end

    test "returns [] when current_user is nil" do
      socket = %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_user: nil}}
      assert Helpers.actor_opts(socket) == []
    end

    test "returns [] when current_user is missing entirely" do
      socket = %Phoenix.LiveView.Socket{assigns: %{}}
      assert Helpers.actor_opts(socket) == []
    end
  end

  describe "actor_uuid/1" do
    test "returns the UUID string when current_user is set" do
      socket = %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_user: %{uuid: "abc"}}}
      assert Helpers.actor_uuid(socket) == "abc"
    end

    test "returns nil when current_user is missing" do
      socket = %Phoenix.LiveView.Socket{assigns: %{}}
      assert Helpers.actor_uuid(socket) == nil
    end
  end
end
