# Remove unused secret-scan clean predicate

- Removed `Gh::ScanResult#clean?`, which had no production caller.
- Kept clean, missing-file, secret-hit, and remote-fetch-failure coverage on
  the `hits` and `fetch_failed` fields consumed by open-PR and finalize gates.
