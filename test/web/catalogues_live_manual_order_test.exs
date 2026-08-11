defmodule PhoenixKitCatalogue.Web.CataloguesLiveManualOrderTest do
  @moduledoc """
  Direct unit coverage for `CataloguesLive.sort_dir_for/2` and
  `manual_order_draggable?/2` — the two pure decision points behind the
  "Manual order" sort option (drag-and-drop catalogue reordering).

  Deliberately plain `ExUnit.Case`, not `LiveCase`: driving these through a
  `handle_event` round-trip (`set_sort`/`toggle_sort`, then asserting on the
  rendered `draggable` attribute) needs `put_cfg/3` to succeed, which calls
  `ViewConfig.save/3` → `user.custom_fields`. The test harness's
  `phoenix_kit_current_user` is never a real `%PhoenixKit.Users.Auth.User{}`
  (see the "manual order — DnD reorder" describe block in
  catalogues_live_test.exs), so that access raises. Testing the extracted
  pure functions directly is what actually exercises this logic instead of
  silently passing with the guard deleted.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Web.CataloguesLive

  # ── sort_dir_for/2 ──────────────────────────────────────────────────
  # Forces :asc whenever the sort lands on "position" (manual order), which
  # has no direction concept — the flip-direction button is hidden while
  # it's active, so a stale :desc carried over from another column would
  # silently invert every drag with no way back.

  describe "sort_dir_for/2" do
    test "landing on manual order from a descending sort forces :asc" do
      assert CataloguesLive.sort_dir_for("position", :desc) == :asc
    end

    test "landing on manual order from an ascending sort stays :asc" do
      assert CataloguesLive.sort_dir_for("position", :asc) == :asc
    end

    test "any other column keeps whatever direction it was given" do
      assert CataloguesLive.sort_dir_for("name", :desc) == :desc
      assert CataloguesLive.sort_dir_for("name", :asc) == :asc
      assert CataloguesLive.sort_dir_for("updated", :desc) == :desc
    end
  end

  # ── manual_order_draggable?/2 ───────────────────────────────────────
  # Drag handles + the SortableGrid hook render only for the unfiltered,
  # unsearched "active" view sorted by "position" — reordering a filtered
  # subset would renumber just those rows against the flat global position
  # sequence and clash with rows outside the filter.

  defp cfg(overrides \\ %{}) do
    Map.merge(%{sort_by: "position", sort_dir: :asc, filters: %{}, search: ""}, overrides)
  end

  describe "manual_order_draggable?/2" do
    test "draggable: active view, manual order, no filters, no search" do
      assert CataloguesLive.manual_order_draggable?("active", cfg())
    end

    test "direction doesn't gate it — a stale :desc is still draggable" do
      assert CataloguesLive.manual_order_draggable?("active", cfg(%{sort_dir: :desc}))
    end

    test "cfg without a :search key at all (never url-synced yet) is still draggable" do
      assert CataloguesLive.manual_order_draggable?("active", %{sort_by: "position", filters: %{}})
    end

    test "not draggable when sorted by anything other than position" do
      refute CataloguesLive.manual_order_draggable?("active", cfg(%{sort_by: "name"}))
    end

    test "not draggable with an active filter" do
      refute CataloguesLive.manual_order_draggable?(
               "active",
               cfg(%{filters: %{"status" => "active"}})
             )
    end

    test "not draggable with a non-empty search" do
      refute CataloguesLive.manual_order_draggable?("active", cfg(%{search: "kitchen"}))
    end

    test "not draggable in the deleted view" do
      refute CataloguesLive.manual_order_draggable?("deleted", cfg())
    end
  end
end
