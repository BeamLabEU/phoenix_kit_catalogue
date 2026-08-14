# PR #61 Review — Item photo preview + product card in the item picker (L026 + L026.1)

**Author:** Tymofii Shapovalov (timujinne)
**Reviewed:** 2026-08-14 (ecosystem sweep)
**Verdict:** APPROVED — merged, with one hardening fix and two dead clauses removed

> A `phase1.md` from an earlier pass sits alongside this file. Its two substantive
> findings were **already addressed in the PR as merged** (the `photo_click` guard and
> the `card_select_image` uuid validation), so this review starts from the merged code
> rather than repeating them.

---

## What landed

`<.item_picker>` gains an opt-in `photo_clickable` attr. When on, the featured-image
thumbnail becomes a button that opens a self-contained `ProductCard` modal *inside the
picker* — no host wiring — and additionally echoes `{:item_picker_photo_click, id,
%Item{}}` upward as a hook for hosts that want to react.

The self-contained design is the right call: the card needs no `handle_info` from the
host, so the upward message is genuinely optional rather than load-bearing.

`card_select_image` validates the incoming uuid against the card's own image set before
assigning it, so a forged event cannot make the card display an arbitrary file — worth
noting because the uuid goes straight into a signed storage URL.

---

## Findings

### BUG - MEDIUM — the upward message could carry `nil` *(fixed on main)*

`photo_click` guarded on `photo_clickable` but not on there *being* a selected item:

```elixir
if socket.assigns.photo_clickable do
  item = socket.assigns.selected_item
  send(self(), {:item_picker_photo_click, socket.assigns.id, item})
  {:noreply, open_card(socket, item)}
```

`open_card/2` had a `defp open_card(socket, _), do: socket` fallback, so the *card* was
nil-safe — but the `send/2` fired first and unconditionally. The moduledoc promises the
message's third element is an `%Item{}`, and a host matching that shape (which the
docs invite) would crash on `nil`.

Reachable when `photo_clickable` is true and nothing is selected: the thumbnail button
isn't rendered then, but a client can push the event anyway — the same threat model the
existing `photo_clickable` guard already accepts as real.

**Fix:** match both conditions at once, so the message is only sent for an actual item:

```elixir
case {socket.assigns.photo_clickable, socket.assigns.selected_item} do
  {true, %Item{} = item} -> …
  _ -> {:noreply, socket}
end
```

**Test added:** `item_picker_card_test.exs` — "a forged photo_click with nothing
selected is inert", pushing the event at the LiveComponent via `with_target/2` (the
host LiveView has no such handler, and that is also where a real forged event lands).
Confirmed non-vacuous: reverting the fix fails it.

### IMPROVEMENT - MEDIUM — two dead clauses dialyzer rejected *(fixed on main)*

`mix precommit` **failed** on the merged code (exit 2, 11 dialyzer errors vs 9 skipped):

```
item_picker.ex:399:8:pattern_match_cov   — open_card(socket, _) can never match
product_card.ex:284:8:pattern_match_cov  — read_uuid(_, _) can never match
```

- `open_card/2`'s nil fallback became unreachable *because of* the fix above, so it was
  removed rather than left as a clause that can never run.
- `read_uuid/2`'s non-map fallback was already unreachable in the PR as submitted: both
  call sites are inside `resolve_images(%Item{data: data}) when is_map(data)`, and
  `Item`'s `:data` field is `default: %{}`. Removed; the `is_map` guard stays as
  documentation of the expectation.

Gate now exits 0 with **zero unskipped dialyzer findings**.

---

## Pre-existing failures — NOT fixed, and not caused by this PR

`mix test` reports **3 failures out of 1430**. All three were verified pre-existing by
checking out the pre-merge commit (`85faa0d`) with its own lockfile (core 2.3.0) and
re-running: same three failures. Neither this PR nor the core 2.4.0 upgrade caused them.

1. **`catalogue_detail_live_test.exs:591`** — "searching writes ?q= into the URL".
   Expected a patch to `…?q=oak`, got `…?q=oak&uuid=<catalogue-uuid>`.
2. **`catalogue_detail_live_test.exs:610`** — "an empty ?category= normalizes to the
   root level". Same `&uuid=` leak.
3. **`catalogues_live_test.exs:314`** — "reorder_catalogues persists the dropped order".
   The order is unchanged after the reorder event (`["A","B","C"]`, expected
   `["C","A","B"]`).

(1) and (2) share a cause worth a proper look: `uuid` is the **route's path parameter**
(`/admin/catalogue/:uuid`), and it is being echoed back into the *query string* by the
`push_url_state` round-trip. That is a real defect in URL-state handling, not a stale
assertion — the test is asking for the right thing.

(3) reads as a genuine behavioural regression in DnD persistence, not a stale test.

Left alone deliberately: diagnosing a core `UrlState` round-trip and a DnD persistence
path is unrelated repair work, well outside this PR's scope, and the sweep was scoped
to the merged PRs. Flagged here and in the sweep report so it is not mistaken for
something this release introduced — but **0.15.0 does ship with these three red**.
