# Remove unused intent receipt query

- Removed `Modules::Migration::EvidenceStore#receipts_for_intent`, which had no
  production caller.
- Retained restart reconciliation coverage by filtering the production receipt
  collection, and kept bounded occurrence-index query coverage used by module
  adapters.
