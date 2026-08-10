## 2026-08-04 — Workflow creator Darwin staging permissions

**Change:** Workflow Creator receipt publication now wraps newly created staging
descriptors as `File` objects and applies descriptor-bound mode `0600` before
writing receipt bytes. This matches Hive's established managed-directory
creation pattern and removes dependence on the platform's initial create mode.

**Proof:** The focused publication suite injects a too-open `0644` created
descriptor and verifies that initialization publishes the exact canonical bytes
as a single-link `0600` file. The protected macOS CI path executes the same
native initialization and replacement flow on Darwin.
