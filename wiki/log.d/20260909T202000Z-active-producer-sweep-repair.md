# Restore the active status producer

A real project Watch regression exposed an undefined active_payload method hidden by a test double. Status now exposes that producer and exact-loads referenced terminal dependencies instead of scanning unrelated history. Explicit task frames bypass retention, and all producers emit an optional v8 projection marker. Earlier v8 payloads remain schema-valid.

The focused Watch, status, dependency and schema set passes 369 tests and 1,885 assertions. Routine consumer migration and the separate archive producer are the next integration steps.
