# 2026-07-26 — Add a read-only Agent CLI Runtime distribution mirror

**Why:** `agent-cli-runtime` needs a focused public description, source browser,
and release history for people who discover the gem independently, while Hive
must remain the single agent-friendly development workspace and release
authority.

**Change:** Added fail-closed mirror tooling under
`components/agent-cli-runtime/mirror/`. A scheduled or manually dispatched
workflow projects the component onto the mirror's `main` branch and records the
exact canonical component commit in `.mirror-source.json`. A separate manual
workflow projects an already approved component tag to an orphan mirror tag,
requires it on canonical main and present on RubyGems, reconstructs and compares
the complete canonical tree, builds and installs the local snapshot, proves the
executable version, and only then pushes the tag and creates the mirror GitHub
release. Third-party Actions are commit-pinned. Tests cover stale-file removal,
symlink rejection before mutation, absent-versus-partial administration-file
handling, package exclusion, workflow YAML parsing, repository scoping,
provenance, and verification-before-publication ordering.

**Boundary:** `ivankuznetsov/agent-cli-runtime` is a read-only distribution
surface. It cannot push to Hive or RubyGems, choose a version, or become an
independent contribution path. Canonical development, issues, pull requests,
component tags, trusted publication, and security ownership remain in Hive.
The gem version was not changed or republished for this metadata and
distribution-only addition.
