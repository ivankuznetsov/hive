# 2026-09-21 — Register benchmark controllers before attempt admission

The cell bootstrap created the native database but only seeded the project in
YAML. Native attempt admission therefore rejected planning before any candidate
session began. Bootstrap now calls the normal idempotent project registration
API after storage setup. A regression test executes the shell bootstrap against
real SQLite storage and verifies registration plus stable identity on retry.
