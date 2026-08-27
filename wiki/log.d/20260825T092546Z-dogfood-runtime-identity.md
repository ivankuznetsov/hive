---
title: Dogfood replaces the active Hive runtime with explicit build identity
type: log
tags: [dogfood, runtime, status, daemon, web, skills]
---

# Dogfood replaces the active Hive runtime with explicit build identity

Added one shared runtime identity projection without changing
`Hive::VERSION`. Release installs default to `channel: release`; dogfood
launchers provide an exact commit and deployment ID and receive a composed
display version such as `0.7.2+dogfood.0864de726`. Invalid annotations degrade
to bounded unknown/null values rather than being echoed. A dogfood identity is
accepted only when both the exact SHA and deployment ID validate, so partial
launcher configuration cannot claim a dogfood build.

`hive version --json`, compact/default status, operational status, daemon
status, and web status now carry the identity under a closed schema. Human
status prints a non-release identity banner. The canonical operating skill
keeps its existing 0.1.5 release metadata; selecting a publish version remains
a separate release decision. Human `hive version` and the strict
`hive --version` package probe remain bare semver. The canonical skill
instructs agents/plugins that normal `hive` is the active
installation: dogfood replaces the installed binary, registry-facing
status, daemon, and web app rather than creating parallel service names or a
stable bypass.

Long-lived processes attest themselves rather than inheriting the inspecting
CLI's claim: the daemon records runtime identity in its ownership-checked PID
receipt, daemon status caches carry that producer identity, and the Rails app
returns its runtime from `/health` for web status. Legacy, unavailable, or
malformed producer evidence projects `unknown` instead of claiming a mixed
cutover succeeded. Compact status also uses the live daemon's receipt when the
daemon is running; unreadable producer evidence fails closed to `unknown`, and
it uses the CLI identity only when the daemon is observably absent.
Runtime remains scoped out of the older strict web-install and setup service
state envelopes, which continue to describe lifecycle rather than build
identity.

Focused tests cover release, complete and partial dogfood metadata, malformed
and invalidly encoded input, exact CLI dispatch,
schema validation, every status producer, and byte-identical OpenClaw
projection regeneration. Live installed proof remains gated on a separately
authorized dogfood cutover because the current machine launcher and service
overrides are deployment-owned outside this repository.
