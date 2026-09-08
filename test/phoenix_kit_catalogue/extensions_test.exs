defmodule PhoenixKitCatalogue.ExtensionsTest do
  @moduledoc """
  Unit tests for the item/category form extension slot's discovery and
  absorption (Block 1, Task 4). Mutates the process-global
  `PhoenixKit.ModuleRegistry`, so `async: false` — see
  `PhoenixKitCatalogue.LiveCase`'s and `supplier_comments_test.exs`'s use of
  `start_supervised!(PhoenixKit.ModuleRegistry)` for the same pattern.
  """
  use ExUnit.Case, async: false

  alias PhoenixKitCatalogue.Extensions
  alias PhoenixKitCatalogue.Test.FakeExtension
  alias PhoenixKitCatalogue.Test.FakeModule

  setup do
    start_supervised!(PhoenixKit.ModuleRegistry)
    :ok
  end

  test "no registered module exports catalogue_extensions/0" do
    assert Extensions.all() == []
    assert Extensions.sections(:item) == []
    assert Extensions.sections(:category) == []
  end

  describe "with FakeExtension registered" do
    setup do
      :ok = PhoenixKit.ModuleRegistry.register(FakeModule)

      # `start_supervised!`'s own teardown has already stopped the
      # registry GenServer by the time this callback runs (its process
      # death races ExUnit's on_exit queue, not LIFO with it), so
      # `unregister/1` — a `GenServer.call` — has nothing to reach.
      # `all_modules/0` reads `:persistent_term` directly with no such
      # requirement, so drop `FakeModule` from that same list the same
      # way: leaving it registered would survive this test (the
      # GenServer stopping does not clear `:persistent_term`) and make
      # every later test's item/category form render the "fake" section
      # and require its `note` field.
      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), FakeModule)
        )
      end)

      :ok
    end

    test "all/0 picks it up" do
      assert Extensions.all() == [FakeExtension]
    end

    test "sections/1 lists it for both :item and :category" do
      assert Extensions.sections(:item) == [FakeExtension]
      assert Extensions.sections(:category) == [FakeExtension]
    end

    test "absorb/3 casts a valid submission under the extension's key" do
      assert Extensions.absorb(:item, %{"fake" => %{"note" => "hi"}}, %{}) ==
               {:ok, %{"fake" => %{"note" => "hi"}}}
    end

    test "absorb/3 returns the extension's cast error, tagged with the module" do
      assert Extensions.absorb(:item, %{"fake" => %{}}, %{}) ==
               {:error, {FakeExtension, [note: "can't be blank"]}}
    end

    test "absorb/3 treats a missing namespace key as an empty submission" do
      assert Extensions.absorb(:category, %{}, %{}) ==
               {:error, {FakeExtension, [note: "can't be blank"]}}
    end

    test "absorb/3 preserves sibling data keys and passes the extension's current value through" do
      assert Extensions.absorb(:item, %{"fake" => %{"note" => "hi"}}, %{
               "_name" => "x",
               "fake" => %{"note" => "old"}
             }) == {:ok, %{"_name" => "x", "fake" => %{"note" => "hi"}}}
    end
  end
end
