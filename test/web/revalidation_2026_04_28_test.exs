defmodule PhoenixKitCatalogue.Web.Revalidation20260428Test do
  @moduledoc """
  Pins the deltas introduced during the 2026-04-28 re-validation pass
  (Batch 2 + Batch 3 of PR #14). Each test pairs with a specific
  change; if the change reverts, the corresponding test here fails.

  See `dev_docs/pull_requests/2026/14-quality-sweep/FOLLOW_UP.md`
  Batch 2 / Batch 3 sections for the revert-fail mapping.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Import.Mapper

  import ExUnit.CaptureLog

  setup do
    cat = fixture_catalogue()
    %{catalogue: cat}
  end

  describe "Batch 2 — handle_info catch-all on every admin LV" do
    test "EventsLive catch-all swallows stray messages and stays alive" do
      original_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original_level) end)

      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/events")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, {:totally_unexpected, :message, %{nested: "payload"}})
          # render forces the LV to flush handle_info — without it the
          # debug log is racing with capture_log's exit.
          _ = render(view)
        end)

      assert Process.alive?(view.pid)
      assert log =~ "EventsLive ignored unhandled message"
    end

    test "CatalogueDetailLive catch-all swallows stray messages", %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/#{cat.uuid}")
      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end

    test "CatalogueFormLive catch-all swallows stray messages" do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/new")
      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end

    test "CategoryFormLive catch-all swallows stray messages", %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogue/#{cat.uuid}/categories/new")

      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end

    test "ItemFormLive catch-all swallows stray messages", %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/#{cat.uuid}/items/new")
      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end

    test "ImportLive catch-all swallows stray messages", %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogue/import?catalogue_uuid=#{cat.uuid}")

      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end
  end

  describe "Batch 2 — PubSub handle_info clauses fire for real broadcasts" do
    test "CataloguesLive refreshes on {:catalogue_data_changed, :catalogue, ...}" do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue")

      # Real broadcast shape from PubSub.broadcast_data_changed/3
      send(
        view.pid,
        {:catalogue_data_changed, :catalogue, "00000000-0000-0000-0000-000000000000", nil}
      )

      assert Process.alive?(view.pid)
      # Re-render shouldn't crash
      assert render(view)
    end

    test "CatalogueDetailLive refreshes on a :catalogue change for its uuid", %{catalogue: cat} do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue/#{cat.uuid}")

      send(view.pid, {:catalogue_data_changed, :catalogue, cat.uuid, nil})
      assert Process.alive?(view.pid)
      assert render(view)
    end

    test "ImportLive handles import_progress + import_result", %{catalogue: cat} do
      {:ok, view, _html} =
        live(conn(), "/en/admin/catalogue/import?catalogue_uuid=#{cat.uuid}")

      send(view.pid, {:import_progress, 5, 10})
      assert Process.alive?(view.pid)
      # import_result triggers log_import_activity + step transition;
      # asserting alive after is sufficient (no DB row pinning here —
      # full activity log is exercised in activity_logging_test).
      send(view.pid, {:import_result, %{inserted: 0, errors: [], skipped: 0}})
      assert Process.alive?(view.pid)
    end
  end

  describe "Batch 2 — phx-disable-with on destructive remove/clear buttons" do
    test "catalogue_form_live source has phx-disable-with on remove_file button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/catalogue_form_live.ex")

      [block] =
        Regex.run(
          ~r/<button[^>]*?phx-click="remove_file"[^>]*?>/s,
          source,
          capture: :all
        ) || [nil]

      assert block, "Expected a remove_file button in catalogue_form_live.ex"
      assert block =~ "phx-disable-with"
    end

    test "item_form_live source has phx-disable-with on remove_file button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/item_form_live.ex")

      [block] =
        Regex.run(
          ~r/<button[^>]*?phx-click="remove_file"[^>]*?>/s,
          source,
          capture: :all
        ) || [nil]

      assert block, "Expected a remove_file button in item_form_live.ex"
      assert block =~ "phx-disable-with"
    end

    test "components.ex has phx-disable-with on every remove_meta_field button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/components.ex")

      blocks =
        Regex.scan(~r/<button[^>]*?phx-click="remove_meta_field"[^>]*?>/s, source)
        |> List.flatten()

      assert length(blocks) >= 2,
             "Expected ≥2 remove_meta_field button declarations (active + legacy)"

      Enum.each(blocks, fn block ->
        assert block =~ "phx-disable-with",
               "Missing phx-disable-with on remove_meta_field button: #{block}"
      end)
    end

    test "components.ex has phx-disable-with on clear_featured_image button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/components.ex")

      [block] =
        Regex.run(
          ~r/<button[^>]*?phx-click="clear_featured_image"[^>]*?>/s,
          source,
          capture: :all
        ) || [nil]

      assert block, "Expected a clear_featured_image button in components.ex"
      assert block =~ "phx-disable-with"
    end

    test "import_live.ex has phx-disable-with on clear_file button" do
      source = File.read!("lib/phoenix_kit_catalogue/web/import_live.ex")

      [block] =
        Regex.run(
          ~r/<button[^>]*?phx-click="clear_file"[^>]*?>/s,
          source,
          capture: :all
        ) || [nil]

      assert block, "Expected a clear_file button in import_live.ex"
      assert block =~ "phx-disable-with"
    end
  end

  describe "Batch 2 — translate_target/1 covers every label from Mapper.available_targets/0" do
    test "every available_target label has a literal-clause translator" do
      # Catches the bug where a new label in Mapper.available_targets/0
      # is not added to import_live.ex's translate_target/1 — which
      # makes the extractor invisible to gettext.extract and leaves the
      # UI label untranslated.
      labels = Enum.map(Mapper.available_targets(), &elem(&1, 1))

      source = File.read!("lib/phoenix_kit_catalogue/web/import_live.ex")

      Enum.each(labels, fn label ->
        # Each label should appear inside a literal `defp translate_target("…"),`
        # clause (the catch-all `defp translate_target(label), do: label` is
        # not enough — the extractor would miss it).
        escaped = Regex.escape(label)
        pattern = ~r/defp\s+translate_target\(\"#{escaped}\"\)/

        assert Regex.match?(pattern, source),
               "Mapper label #{inspect(label)} has no `defp translate_target/1` clause in import_live.ex — extractor invisible."
      end)
    end
  end

  describe "Batch 2 — ActivityLog rescue widened" do
    test "ActivityLog.log/1 swallows DBConnection.OwnershipError silently" do
      # Async PubSub broadcasts crossing into a logging path without
      # sandbox checkout raise OwnershipError, not Postgrex.Error.
      # Simulate by spawning an unowned process and calling log/1 from
      # there. The rescue must convert this into :ok, no warning.
      log =
        capture_log(fn ->
          parent = self()

          spawn(fn ->
            result =
              ActivityLog.log(%{
                action: "catalogue.test.ownership_error",
                resource_type: "catalogue",
                resource_uuid: Ecto.UUID.generate()
              })

            send(parent, {:done, result})
          end)

          assert_receive {:done, :ok}, 1_000
        end)

      refute log =~ "PhoenixKitCatalogue activity log failed",
             "Expected DBConnection.OwnershipError to be swallowed silently, but got warning."
    end
  end

  defp conn, do: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
end
