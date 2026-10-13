# Follow-up — PR #147 and #148

| Finding | Resolution |
|---|---|
| #148 BUG - MEDIUM: nested rollback from a refused folder move | Fixed: `free_name/3` returns `nil`, `relocate/4` skips the write. Test added in `media_folders_test.exs`. |
| #148 IMPROVEMENT - MEDIUM: items' folders after hard `delete_category`/`delete_catalogue` | Not changed — documented behaviour, files stay reachable by pointer. |
| #148 NITPICK: bulk-move query bound | Raised 400 → 800 with the reason in the test comment. |
| Suite red on HEAD (core 2.62.2 drops the locale segment on single-language sites) | `test/test_helper.exs` turns the test site multilingual with the prefix kept; `Test.Router` serves both `/en/admin/...` and `/admin/...` in one live session. 3719 tests green. |
| #147 | No findings. |
