# PR #62 Phase 1 Review — phoenix_kit_catalogue
**Title:** Handover notes: what shipped, what was designed but not built, what to watch out for
**Author:** Tymofii Shapovalov (timujinne)
**Verdict:** APPROVE WITH NOTES

---

## Summary

Single-file PR adding `HANDOVER.md` at the repo root (84 lines, 0 deletions, no
code changes). Tymofii is wrapping up LAISK-loop work on the catalogue module
and leaving institutional knowledge for the next maintainer. The document is
well-structured, honest about what was and wasn't done, and surfaces several
non-obvious gotchas that would otherwise cost a successor significant discovery
time.

The content is accurate and complete at the level expected for a handover doc.
One section — the consumer contract for `photo_clickable` — contains a
**crash-risk warning** that is important enough to surface prominently. The rest
is solid orientation material.

No version bump, no migrations, no dependency changes, no tests added. Pure docs.

---

## Findings

### Blockers

None.

### Non-blockers

1. **Opaque ticket references (L028 / L029).**
   The "Not done" section cites internal ticket IDs (`our L028`, `our L029`)
   with no link or system name. A maintainer outside the LAISK loop won't know
   where to find these. Suggest either linking them (Linear/Jira/GitHub issue) or
   replacing with a brief inline description (which already exists, so this is
   just about the reference, not the content).

2. **Pre-existing failing tests — no tracking tickets.**
   Section 3 names 3 failing tests on `main` (`CatalogueDetailLiveTest` URL
   state tests, `CataloguesLiveTest` DnD reorder) but doesn't reference any open
   issue tracking them. Worth filing a GitHub issue (or noting an existing one)
   so they don't quietly rot unassigned. A future CI run will look broken to
   someone who doesn't know about these.

3. **Spectator-host staleness — no tracking either.**
   Same pattern: named as a known issue but no open issue referenced. Low
   severity in practice (narrow host pattern required), but tracking keeps it
   from being rediscovered as a bug.

4. **File placement — `HANDOVER.md` at root.**
   Not wrong — root-level is highly visible and the PR description acknowledges
   the maintainer can move it to a wiki or issue. Root is a reasonable choice
   for discoverability. If the repo has a `dev_docs/` convention already, a
   `dev_docs/HANDOVER.md` might be more consistent, but this is a preference
   call, not a blocker. The PR description explicitly punts to maintainer
   discretion, which is the right call.

### Nitpicks

- **Section 1 table**: `90129ae` is listed as a bare commit hash without a PR
  number. A short description or a link would help traceability.
- **Consumer contract formatting**: The crash risk (`Without a clause the click
  crashes that LiveView`) is buried mid-paragraph. A bold callout or `> ⚠️`
  blockquote would catch a skimmer's eye. This is the single highest-stakes
  piece of information in the document.
- **L029 draft**: "Draft only" is slightly vague — is there a design doc, a
  branch, a sketch somewhere? Even "design lives in Slack thread
  #..., no artifacts yet" would help.

---

## Assessment

The document is accurate and clearly written. The consumer contract section is
the most operationally critical part — it documents a crash-risk pattern that
`photo_clickable` hosts will hit if they miss the `handle_info/2` clause. That
warning is present and correct; it just deserves visual emphasis.

The gettext-is-manual warning is equally non-obvious and well-placed. Running
`mix gettext.extract` is a natural impulse that would silently destroy translations
— documenting it here is exactly the right thing to do.

No changes to the codebase, no version bump required. This can merge as-is.

---

## Stats
- **Tests:** none added (pure docs)
- **Migrations:** none
- **Version bump:** not needed
- **Dependency changes:** none
- **Changed files:** 1 (`HANDOVER.md`, new file)
