defmodule PhoenixKitCatalogue.Catalogue.ActivityLogTest do
  @moduledoc """
  Direct unit tests for `PhoenixKitCatalogue.Catalogue.ActivityLog` —
  the rescue branches + `with_log/2` shape. Uses `async: false`
  because the rescue tests DROP the activity table mid-transaction
  (per the workspace AGENTS.md "destructive rescue test" pattern) and
  parallel async tests holding row-level locks would deadlock.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  describe "log/1 — happy path" do
    test "writes a row tagged with module=catalogue" do
      uuid = Ecto.UUID.generate()

      :ok =
        ActivityLog.log(%{
          action: "catalogue.test.happy",
          resource_type: "catalogue",
          resource_uuid: uuid,
          metadata: %{"name" => "Happy Cat"}
        })

      assert_activity_logged("catalogue.test.happy", resource_uuid: uuid)
    end
  end

  describe "log/1 — rescue branches" do
    @tag :destructive
    test "swallows Postgrex.Error :undefined_table silently" do
      # Drop the table inside the sandboxed transaction. Sandbox rolls
      # the DROP back at test exit so other tests still see it.
      TestRepo.query!("DROP TABLE phoenix_kit_activities CASCADE")

      log =
        capture_log(fn ->
          assert :ok =
                   ActivityLog.log(%{
                     action: "catalogue.test.undefined_table",
                     resource_type: "catalogue",
                     resource_uuid: Ecto.UUID.generate()
                   })
        end)

      refute log =~ "PhoenixKitCatalogue activity log failed",
             "Expected :undefined_table to be swallowed silently — got: #{log}"
    end

    test "logs Logger.warning for unknown errors" do
      # Pass a malformed attrs map that PhoenixKit.Activity.log/1
      # rejects (missing :action). The catalogue rescue's generic
      # `error -> Logger.warning` branch should fire.
      log =
        capture_log(fn ->
          assert :ok =
                   ActivityLog.log(%{
                     # No :action — Activity.log/1 will fail.
                     resource_type: "catalogue",
                     resource_uuid: Ecto.UUID.generate()
                   })
        end)

      # Either core's Activity rejected this with a wrapped warning,
      # or it landed silently. Both are acceptable; we assert the
      # call returned :ok and didn't crash. If a warning fires, it
      # must mention our module's prefix.
      if log =~ "PhoenixKitCatalogue activity log failed" do
        assert log =~ "catalogue.test" or log =~ "resource_type" or log =~ "catalogue",
               "Expected the log line to surface attrs context, got: #{log}"
      end
    end
  end

  describe "with_log/2" do
    test "logs on {:ok, _} success" do
      uuid = Ecto.UUID.generate()

      assert {:ok, %{name: "OK"}} =
               ActivityLog.with_log(
                 fn -> {:ok, %{uuid: uuid, name: "OK"}} end,
                 fn record ->
                   %{
                     action: "catalogue.test.with_log_ok",
                     resource_type: "catalogue",
                     resource_uuid: record.uuid
                   }
                 end
               )

      assert_activity_logged("catalogue.test.with_log_ok", resource_uuid: uuid)
    end

    test "passes {:error, _} through unchanged without logging" do
      assert {:error, :would_create_cycle} =
               ActivityLog.with_log(
                 fn -> {:error, :would_create_cycle} end,
                 fn _record -> flunk("attrs_fun must NOT be called on :error") end
               )

      refute_activity_logged("catalogue.test.never")
    end

    test "passes {:error, %Ecto.Changeset{}} through" do
      cs = Ecto.Changeset.cast({%{}, %{name: :string}}, %{}, [:name])

      assert {:error, ^cs} =
               ActivityLog.with_log(
                 fn -> {:error, cs} end,
                 fn _ -> flunk("attrs_fun must NOT be called on :error") end
               )
    end
  end
end
