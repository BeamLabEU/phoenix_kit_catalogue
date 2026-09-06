defmodule PhoenixKitCatalogue.AIPromptTest do
  @moduledoc """
  Unit coverage for `PhoenixKitCatalogue.AIPrompt.ensure_prompt/0` — the
  idempotent-by-slug provisioning of the catalogue translation prompt,
  and its `content_sha`-driven rollout when the template changes.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.AIPrompt

  describe "ensure_prompt/0" do
    test "creates the prompt on first call under the expected slug" do
      assert {:ok, uuid} = AIPrompt.ensure_prompt()

      prompt = PhoenixKitAI.get_prompt(uuid)
      assert prompt.slug == AIPrompt.slug()
      assert is_binary(prompt.metadata["content_sha"])
      assert prompt.metadata["managed_by"] == "phoenix_kit_catalogue"
    end

    test "is idempotent by slug — repeated calls return the same uuid" do
      assert {:ok, uuid1} = AIPrompt.ensure_prompt()
      assert {:ok, uuid2} = AIPrompt.ensure_prompt()
      assert uuid1 == uuid2

      # No duplicate row was inserted under the slug.
      assert PhoenixKitAI.get_prompt_by_slug(AIPrompt.slug()).uuid == uuid1
    end

    test "does not rewrite the stored row when content_sha already matches" do
      {:ok, uuid} = AIPrompt.ensure_prompt()
      before = PhoenixKitAI.get_prompt(uuid)

      {:ok, ^uuid} = AIPrompt.ensure_prompt()
      after_second_call = PhoenixKitAI.get_prompt(uuid)

      assert before.updated_at == after_second_call.updated_at
    end

    test "updates the stored prompt in place when the template has evolved" do
      {:ok, uuid} = AIPrompt.ensure_prompt()
      prompt = PhoenixKitAI.get_prompt(uuid)

      # Simulate a shipped rule change that predates this deploy: the
      # stored row still carries an older template and content_sha.
      {:ok, stale} =
        PhoenixKitAI.update_prompt(prompt, %{
          content: "An older, since-replaced catalogue translation prompt.",
          metadata: %{"managed_by" => "phoenix_kit_catalogue", "content_sha" => "deadbeef"}
        })

      refute stale.content == prompt.content

      assert {:ok, ^uuid} = AIPrompt.ensure_prompt()

      updated = PhoenixKitAI.get_prompt(uuid)
      assert updated.content == prompt.content
      assert updated.metadata["content_sha"] == prompt.metadata["content_sha"]
      refute updated.metadata["content_sha"] == "deadbeef"
    end
  end
end
