defmodule PhoenixKitCatalogue.AIPromptGlossaryRolloutTest do
  @moduledoc """
  The rollout this feature promises, exercised against a real database
  rather than inferred from reading `maybe_update/2`: a prompt stored by an
  install whose `phoenix_kit_ai` does not bind `{{Glossary}}` is rewritten
  IN PLACE, under the same uuid, once that install upgrades — and back again
  on a downgrade.

  Both directions matter. The uuid has to survive because callers hold a
  `prompt_uuid`; the `content_sha` has to follow the new content or the next
  call would rewrite the row again on every single request.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.AIPrompt

  @slot "{{Glossary}}"

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  describe "upgrading phoenix_kit_ai adds the slot in place" do
    test "item/category prompt keeps its uuid and re-stamps content_sha" do
      assert {:ok, uuid} = AIPrompt.ensure_prompt(false)
      before = PhoenixKitAI.get_prompt(uuid)
      refute before.content =~ @slot
      assert before.metadata["content_sha"] == sha(before.content)

      assert {:ok, ^uuid} = AIPrompt.ensure_prompt(true)
      upgraded = PhoenixKitAI.get_prompt(uuid)

      assert upgraded.content =~ @slot
      assert upgraded.metadata["content_sha"] == sha(upgraded.content)
      refute upgraded.metadata["content_sha"] == before.metadata["content_sha"]
    end

    test "attribute-set prompt behaves the same" do
      assert {:ok, uuid} = AIPrompt.ensure_sets_prompt(false)
      refute PhoenixKitAI.get_prompt(uuid).content =~ @slot

      assert {:ok, ^uuid} = AIPrompt.ensure_sets_prompt(true)
      upgraded = PhoenixKitAI.get_prompt(uuid)

      assert upgraded.content =~ @slot
      assert upgraded.metadata["content_sha"] == sha(upgraded.content)
    end

    test "a second call at the same capability rewrites nothing" do
      # Otherwise every `ensure_prompt/0` — and these run from a LiveView
      # mount — would write to the database on each connect.
      assert {:ok, uuid} = AIPrompt.ensure_prompt(true)
      first = PhoenixKitAI.get_prompt(uuid)

      assert {:ok, ^uuid} = AIPrompt.ensure_prompt(true)
      second = PhoenixKitAI.get_prompt(uuid)

      assert second.updated_at == first.updated_at
    end
  end

  describe "downgrading removes the slot the same way" do
    test "item/category prompt loses the slot, keeps its uuid" do
      assert {:ok, uuid} = AIPrompt.ensure_prompt(true)
      assert PhoenixKitAI.get_prompt(uuid).content =~ @slot

      assert {:ok, ^uuid} = AIPrompt.ensure_prompt(false)
      downgraded = PhoenixKitAI.get_prompt(uuid)

      refute downgraded.content =~ @slot
      assert downgraded.metadata["content_sha"] == sha(downgraded.content)
    end
  end
end
