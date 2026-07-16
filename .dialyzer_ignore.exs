[
  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2. Known upstream false positive.
  {"lib/phoenix_kit_catalogue/gettext.ex", :call_without_opaque},

  # Ecto.Multi/Ecto.Query are @opaque; piping a freshly-built query into
  # Multi.update_all/3 makes dialyzer flag the opaque-subterm mismatch even
  # though the call is correct. Same known Ecto+dialyzer false positive as
  # the gettext.ex entry above.
  {"lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex", :call_without_opaque},

  # Mix tasks: the :mix application isn't in the dialyzer PLT, so any call
  # into Mix.Task/Mix.shell() reads as an unknown callback/function. Inherent
  # to dialyzing a Mix.Task module, not specific to this file's code.
  {"lib/mix/tasks/phoenix_kit_catalogue.audit_supplier_refs.ex", :callback_info_missing},
  {"lib/mix/tasks/phoenix_kit_catalogue.audit_supplier_refs.ex", :unknown_function}
]
