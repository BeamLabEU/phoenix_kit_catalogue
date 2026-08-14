# PR #61 Phase 1 Review — phoenix_kit_catalogue
**Title:** Add a main-image thumbnail preview to the catalogue item picker
**Author:** Tymofii Shapovalov (timujinne)
**Date:** 2026-08-14
**Verdict:** APPROVE WITH NOTES

---

## Summary

Adds an optional `featured_image_uuid`-driven thumbnail to the left of the `ItemPicker` input. When a selected item carries a photo, a small `w-8 h-8` rounded img is shown. The `photo_clickable` attr (default `false`) wraps it in a `phx-click` button that echoes `{:item_picker_photo_click, id, %Item{}}` upward — a navigation hook for the upcoming product-card feature (L026.1). Also includes three regression tests pinning the reimport photo-preservation invariant (executor insert-only, pro100 merge preserves photo pointers).

Implementation follows the existing `featured_image_card/1` pattern (`URLSigner.signed_url/2`). The opt-in design is safe for existing consumers: no `photo_clickable` → inert image only, no new messages fired.

5 files changed. No migrations. No dependency changes. No version bump (pending L026.1 product-card completion).

---

## Findings

### Blockers

_None._

### Non-blockers

1. **Unguarded `photo_click` event handler** — `handle_event("photo_click", ...)` fires on any inbound event named `photo_click`, even when `socket.assigns.photo_clickable` is `false`. The template only renders the clickable `<button>` when `@photo_clickable` is true, so a normal user can't trigger it through the UI. However, a forged client-side `pushEvent("photo_click", ...)` would still invoke the handler and `send(self(), {:item_picker_photo_click, id, selected_item})` to the parent LiveView — which, if it has no `handle_info` clause for that message, will crash the LV process.

   **Risk level:** Low (internal tool, authenticated users only). **Fix:** Add an early-return guard:
   ```elixir
   def handle_event("photo_click", _params, %{assigns: %{photo_clickable: false}} = socket) do
     {:noreply, socket}
   end
   def handle_event("photo_click", _params, socket) do
     send(self(), {:item_picker_photo_click, socket.assigns.id, socket.assigns.selected_item})
     {:noreply, socket}
   end
   ```

2. **`selected_item` can be `nil` when `photo_click` fires** — Even in the guarded path, if `selected_item` is somehow `nil` (race condition, stale socket state), the parent receives `{:item_picker_photo_click, id, nil}`. Defensive parents should pattern-match on `%Item{}`, but it's worth documenting in the moduledoc that the item in the message is guaranteed non-nil only when the button is rendered.

### Nitpicks

1. **No live-click test for `photo_clickable`** — The `photo_clickable=true` test (`item_picker_test.exs:395`) asserts the rendered HTML contains `phx-click="photo_click"`, but doesn't simulate a click event and assert the parent receives `{:item_picker_photo_click, ...}`. A `render_click/2` + `assert_received` pair would close this gap.

2. **`URLSigner.signed_url/2` called per-render** — Called each time the component re-renders. Consistent with existing `featured_image_card/1` usage and assumed cheap (local HMAC). Not a concern unless profiling shows otherwise.

3. **Template indentation** — The new `flex` wrapper and inner `relative flex-1` div add nesting depth. The `<script>` (colocated hook) correctly stays outside both new divs, and dropdown positioning relative to the input area is preserved. Structurally correct, but worth a visual sanity check in the running app.

4. **No version bump** — PR description says feature is pending L026.1 integration, so no bump makes sense. Confirm intentional at release time.

---

## Stats

| | |
|---|---|
| **Additions** | 221 |
| **Deletions** | 1 |
| **Changed files** | 5 |
| **Tests added** | 9 (6 item_picker + 2 pro100_plan + 1 executor) |
| **Migrations** | None |
| **Version bump** | None |
| **Dependency changes** | None |

---

## Test coverage

- `test/web/item_picker_test.exs`: 6 new tests — thumbnail with photo, without photo, no selection, blank UUID, inert by default, clickable when opted in.
- `test/phoenix_kit_catalogue/import/pro100_plan_test.exs`: 2 new — reimport update and nochange both preserve `featured_image_uuid` + `files_folder_uuid`.
- `test/import/executor_test.exs`: 1 new — insert-only reimport leaves existing photographed item's data intact.
- Suite reported 1410 tests, 3 pre-existing failures (DnD reorder, `?q=`/`?category=` LiveView). **0 new failures.**

---

## Recommendation

Approve. The one non-blocker (unguarded event handler) is worth a quick one-liner fix before merge, but the risk is low enough that it doesn't block. All other aspects — design, test coverage, security, performance — are solid. The reimport invariant tests are a welcome addition.
