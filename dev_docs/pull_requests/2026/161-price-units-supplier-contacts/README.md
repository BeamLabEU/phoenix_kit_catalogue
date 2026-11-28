# Price units and supplier contacts

[PR #161](https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/161) adds day, week, month and year as service price units. Item forms display translated labels, and imports recognize localized names and abbreviations.

Migration V8 creates supplier contact rows and backfills each nonblank legacy contact value. A supplier can have several contacts of one kind. A partial unique index enforces one primary per kind, and the existing `contact_info` field holds a summary of the primaries. Supplier edits take the supplier row lock so concurrent edits build on the latest committed list.
