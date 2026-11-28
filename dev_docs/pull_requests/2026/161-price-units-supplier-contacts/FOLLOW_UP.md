# Review fixes

- Limited primary election during incremental edits to the affected kind. Added a regression test covering an unknown deletion, addition, selection and removal after clearing the legacy summary.
- Included explicitly retained UUIDs in the equality check. A regression test swaps two identical secondary contacts by UUID and checks the returned order.
- Read both the supplier and its ordered contacts under the same transaction lock for changed and unchanged results.
- Added both year aliases and covered them in the importer tests.
- Restored the dimensions fields in the form fixture and normalized the optional core admin attribute in the snapshot comparison.
