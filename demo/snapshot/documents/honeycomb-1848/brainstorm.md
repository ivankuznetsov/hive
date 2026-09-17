<!-- AGENT_WORKING pid=1904284 started=2026-07-09T13:02:53Z -->

# Brainstorm: registry-layout-package-manifest-schema

Scope: define the **honeycomb** package format (`packages/<name>/` with
`workflow.yml`, `instructions/`, `README.md`, `manifest.yml`), the generated
top-level `catalog.json`, and a stdlib-only Ruby validator. The seed is
detailed; the questions below target the genuine ambiguities, edge cases, and
what "done" means.

## Round 1

### Q1. Manifest authorship: generated or hand-written?
The seed says sha256-of-every-file and the permissions summary are
"auto-derived from the descriptor." That implies a *generator/build* tool, not
just a validator. Is a `manifest.yml` generator (that computes shas + writes
the permissions summary) in scope for this honeycomb, or is `manifest.yml`
hand-authored with only the validator checking it? If generated, is the tool
also Ruby-stdlib-only, and do authors run it manually or does CI regenerate?
### A1.
Generated. Ship Ruby-stdlib tooling that derives the permissions summary and a
SHA-256 for every package file except `manifest.yml` itself, then writes a
deterministically ordered manifest. Authors run it explicitly; CI runs a
`--check` mode and fails on drift. The validator remains a separate read-only
command and never silently rewrites submissions.

### Q2. Versioning & directory layout for multiple versions
`packages/<name>/` maps one directory to one package. How do multiple published
versions coexist? Options: (a) directory always holds the latest, history lives
in git tags; (b) `packages/<name>/<version>/`; (c) version is a manifest field
only and re-publishing overwrites. What is the uniqueness/immutability rule
(can a published version's files change)?
### A2.
Use immutable version directories:
`packages/<name>/<semver>/`. A merged version may never be changed; corrections
require a new version. `catalog.json` records every listed version and a
`latest_version` selected by SemVer, while the default install command resolves
that latest listed version. Git history is provenance, not the version store.

### Q3. What does the "permissions summary" actually summarize?
What permission-bearing constructs does a hive descriptor (`workflow.yml`)
express — tool allowlists, shell/network access, file-write scopes, per-stage
grants? What shape should the derived summary take in `manifest.yml` (flat list,
per-stage map, coarse risk tier)? A concrete example of the input descriptor
fields and the desired output would anchor this.
### A3.
Derive a normalized permission object from `workflow.yml`: `risk`,
`capabilities` (shell, network, filesystem-read, filesystem-write),
`network_hosts`, `filesystem.read`, `filesystem.write`, and `secrets` (names,
never values). Preserve per-stage evidence in validation output, but publish the
worst-case union in the manifest/catalog. Undeclared or unbounded access raises
the risk tier; generation must fail when a requested capability cannot be
represented rather than omitting it.

### Q4. `catalog.json` — ownership, trigger, and contents
Which fields from each `manifest.yml` land in `catalog.json`, and does it embed
full manifests or just an index (name, version, description, permissions tier,
path)? Who generates it and when — is generation part of *this* honeycomb's
tooling, or owned by the sibling CI honeycomb? Should the generator be the same
Ruby script family as the validator?
### A4.
This task owns the Ruby generator for root `catalog.json`; the security CI task
invokes it in `--check` mode. The catalog is an index, not embedded manifests.
Each entry includes name/version/description/tier/author/license/Hive minimum,
the normalized permission summary, install command, package/reviews URLs,
source SHA, and listing approval metadata. Generate it after manifest
validation and include only versions with both lint and human-approval records.

### Q5. Validator behavior: exit codes, output, and the hive soft-dep
When the `hive` gem is **absent**, should descriptor validation be skipped with
a warning (still exit 0) or hard-fail? What is the machine-readable contract —
exit codes, and human vs. JSON output (the CI/comment honeycomb will consume
it)? Does it validate one package, all packages, or both modes? Is this
validator the authoritative CI gate, or does the sibling security-lint CI
honeycomb wrap it?
### A5.
Support one package path or all packages, human output by default and `--json`
with a stable array of `{path, code, message, severity}` findings. Exit 0 on
success, 1 on validation findings, and 2 on invocation/internal errors. The
authoritative structural validation is Ruby-stdlib-only and does not require
the Hive gem; when Hive is installed, run its descriptor parser as an extra
compatibility check. Absence is a warning locally, while CI installs the pinned
minimum Hive version and requires the compatibility check. The security-lint
honeycomb wraps this validator rather than duplicating it.

### Q6. hive-bench corpus conventions to mirror
The seed says to reuse the hive-bench "manifest+sha pattern." Do you have a
canonical corpus entry I (or the plan stage) can point to for the exact sha
format (per-file map? `sha256sums`-style lines? algorithm-prefixed?) and field
names? Should honeycomb manifests be a strict superset of that format, or just
spiritually similar? Where does that corpus live?
### A6.
Mirror the hive-bench principles, not its schema. Use a YAML mapping of
repo-relative file path to lowercase 64-character SHA-256 digest, sorted by
path. Document hive-bench's `corpus/SCHEMA.md` and a current corpus manifest as
design references, but define `honeycomb-manifest` v1 independently because it
hashes a whole publishable package rather than one held-out patch.

### Q7. Required vs optional manifest fields, and validation strictness
Of {name, version(semver), author, license, hive-min-version, description,
permissions-summary, file-shas} — which are hard-required (validator fails if
missing) vs optional? Any constraints: license from an SPDX allowlist? author
format (name/email/handle)? name charset/regex (since it becomes a directory
and a catalog key)? Unknown/extra keys — reject or tolerate?
### A7.
Require schema/version, name, SemVer version, description, author, SPDX license,
Hive minimum version, source/provenance, permissions, and file hashes. Names use
`\A[a-z0-9][a-z0-9-]{1,62}[a-z0-9]\z`; directory name and manifest name must
match. Author is `{name, url}` with URL optional. License must be a valid SPDX
identifier from a checked-in allowlist. Reject unknown top-level keys in schema
v1 except namespaced `x-*` extensions; validate all known nested keys strictly.

### Q8. Acceptance criteria & definition of done
What must exist for this honeycomb to be complete? For example: (a) the format
documented in a spec/README; (b) at least one real reference honeycomb under
`packages/` that passes the validator end-to-end; (c) a generated `catalog.json`
checked in; (d) the validator runnable as `ruby validate.rb` with green/red
output. Which of these are in scope here vs. deferred to sibling honeycombs
(catalog page, seeding, CI)? Name the smallest concrete artifact set you want to
see land.
### A8.
Land: a format specification and example; deterministic generate/check tooling;
single/all-package validator with JSON output; tests for valid, malformed,
tampered, path-traversal, and drift cases; and root catalog generation with an
empty catalog plus test fixtures. Real `packages/bench` and `packages/docs-sync`
belong to task 1851, and listing CI belongs to 1849. Task 1848 is complete when
the fixture passes end to end and CI can invoke the documented commands without
network access.

<!-- COMPLETE -->
