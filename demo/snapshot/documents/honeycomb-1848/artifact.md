# Artifacts — Package Registry Manifest Schema

Task `registry-layout-package-manifest-schema-260709-1f1a` (PR
[#1](https://github.com/ivankuznetsov/honeycomb/pull/1), draft). It adds the
`honeycomb-manifest/v1` package contract plus offline, Ruby-stdlib tooling that
turns a version directory into a verifiable, listable package.

## Release / handoff artifacts

- **CLI commands** (`script/`, one shared library `lib/honeycomb_registry/`):
  - `honeycomb-manifest` — generate/`--check` the canonical `manifest.yml`
  - `honeycomb-validate` — read-only validation (`--all`, `--json`, `--require-hive`)
  - `honeycomb-catalog` — generate/`--check` the evidence-gated `catalog.json`
  - Exit contract for all three: `0` ok · `1` drift/validation error · `2` invocation/internal.
- **Format spec** — `docs/PACKAGE_FORMAT.md` (~286 lines): layout, schemas,
  integrity model, evidence boundary, permission projection, command contract.
- **Canonical `catalog.json`** — checked-in empty root (canonical until seed
  honeycombs land); `packages/` holds only `.gitkeep`.
- **License policy data** — `policy/spdx-license-ids.txt`.
- **Wiki updates** — architecture, command-api-surface, decisions, dependencies,
  gaps, and three new contract pages (package-catalog, security-review,
  registry-package-contract log fragment).

No additional binary/release bundles are produced by this task; it is a
library + CLI contract, not a packaged deliverable.

## Verification (re-run this stage, offline, stdlib only)

- `ruby test/run.rb` → **65 runs, 327 assertions, 0 failures, 0 errors, 0 skips**.
- End-to-end flow reproduced against a scratch registry seeded from
  `test/fixtures/packages/valid/example/1.0.0`:
  - `honeycomb-manifest` generate + `--check --all` → exit 0 (bytes stable).
  - `honeycomb-validate --all --json` → `hive.compatible` info only, exit 0.
  - `honeycomb-catalog --evidence passing.json` → one `reviewed` entry
    (`example` 1.0.0) with `install_command` and an `approval` bound to the
    matching `release_sha256` + `head_sha`; `--check` re-run → exit 0.

## Visual demo capture

Surface is a **CLI** (recorded under `surface: "tui"`). `asciinema`, `vhs`, and
`agg` are not installed, so instead of a live screencast the terminal session
was rendered from **verbatim captured command output** into terminal-style stills
(ImageMagick/pango) and assembled into a GIF with `ffmpeg`/ImageMagick. All text
shown is real output from the runs above.

- `media/01-generate-manifest.png` — generate + `--check` byte stability
- `media/02-manifest-yml.png` — generated manifest (permissions, file hashes, `release_sha256`)
- `media/03-validate.png` — offline `validate --all --json`
- `media/04-catalog-listing.png` — evidence-gated catalog entry
- `media/05-tests.png` — green test suite
- `media/demo.gif` — the four-step flow end to end
- `media/manifest.json` — `status: "captured"`, `surface: "tui"`

Screenote is not connected (`hive connect screenote`), so every `screenote_url`
is `null` with the unavailable reason recorded per item; media is kept local.

<!-- COMPLETE -->
