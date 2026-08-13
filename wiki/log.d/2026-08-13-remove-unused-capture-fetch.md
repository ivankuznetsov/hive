# Remove unused capture fetch

- Removed `Modules::Migration::EvidenceStore#fetch_capture`, which had no
  production caller.
- Kept restart, malformed-record, oversized-record, and no-follow capture
  coverage through the production `captures` collection reader.
