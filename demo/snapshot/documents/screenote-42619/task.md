---
slug: add-image-attachments-to-screenote-260816-6a00
started_at: 2026-08-29T01:37:13Z
---

# add-image-attachments-to-screenote-260816-6a00

## Implementation


## Execute Output

Implementation complete. All six units are in, the worktree is clean, and every repository gate passes.

## Commits

| Commit | Unit |
|---|---|
| `3c17e00` | U1 — domain, constraints, ingest, claim |
| `6d796a5` | U2 — session draft endpoints, authorization, cleanup |
| `ebbb847` | U4 — parent submission and deletion lifecycle |
| `1fb5fe3` | U3+U5 — composer UX, gallery, viewer |
| `69af5a4` | U6 — REST/MCP/CLI/digest/wiki (carries the completion trailer) |

U4 landed before U3/U5 because the composer JS depends on the submission JSON contract.

## What was built

Draft batches with an unguessable public ID that doubles as the one-use submission key; ingest that persists the `uploading` row before streaming, decodes fully through the global two-slot guard outside any lock, and serializes only the aggregate recheck; atomic claim in fixed lock order that binds a ready set to a parent created in the same transaction. One Stimulus composer across the overlay rail and both sidebar disclosures, with picker/drop/paste, progress, retry, removal, alt text, blocked submit, and 422 rehydration. Two application-streamed media routes (session and bearer + five-minute purpose token), neither redirecting to the provider. `attachments` on the root annotation and every comment in REST/MCP/CLI detail reads, plus digest metadata and a viewport deep link.

## Tests run

- Full Rails suite: **1858 runs, 0 failures, 0 errors** (54 skips)
- `bin/rubocop` clean (494 files); `bin/brakeman -q`: 0 warnings
- Go: `go vet` and `go test ./...` pass, including a new attachment decode test
- Browser: `test/system/image_attachments_test.rb` — 11/11 pass; `test/system/annotations_test.rb` — 2 failures that I verified fail identically at the pre-change baseline (`comment_form_follows_a_long_screenshot`, `project_members_see_distinct_author_markers`)

One regression I did introduce and fix: posting via `Turbo.visit` dropped fullscreen review state, so submission now reloads the workspace Turbo frame instead, matching the old form-submission contract.

## Two deviations worth your attention

**The PostgreSQL job is a separate workflow.** `DatabasePortabilityContractTest` scans `ci.yml` and fails on any PostgreSQL-specific string, so the plan's "PostgreSQL CI job" lives in a new `.github/workflows/concurrency-qualification.yml` rather than in `ci.yml`. It drives the adapter through `DATABASE_URL` without touching `config/database.yml`.

**The overlay cannot guarantee zero region overlap once an image is attached.** The plan asks that the rail "never covers the selected screenshot region." An empty rail now costs the clamped form no height at all (it dissolves into the existing action row), so the existing zero-overlap contract still holds. But with a thumbnail row the form is ~230px tall against a 300px-tall test screenshot — no placement avoids the region. The placement algorithm already minimizes overlap; my test asserts the rail stays one compact row inside the image instead of asserting zero overlap. Logged in `wiki/gaps.md`.

Also logged there: attachment delivery is proven against Disk storage only — the plan's required Rabata/S3 no-redirect and expiry evidence is still outstanding before release.

## Execute Output

Done. Two commits on `add-image-attachments-to-screenote-260816-6a00`, worktree clean.

## What changed

Every reviewer failure was about a claim that existed only as a diff to read. Each one now has a way to run.

**`585fddf` — execute the lifecycle and provider-delivery claims**
- The image attachment lifecycle suites moved out of a hard-coded CI workflow list into `script/release_test_matrix attachment-lifecycle`, which runs against whatever database is configured. `script/attachment_server_database_qualification` boots an ephemeral server database and reruns the *identical* list under real row locks, so the account byte-ceiling race and the adapter assertion are no longer reachable only inside GitHub Actions.
- New `test/integration/image_attachment_s3_delivery_contract_test.rb` points the whole application at a real object store and drives the protected session and bearer routes through it — provider-stored bytes, no `Location`, no provider host in any header, application-served byte ranges, five-minute token expiry, revoked membership losing access. It joins the existing `s3` release gate. `test/support/s3_contract_helper.rb` shares the wiring with the existing contract.
- `.tool-versions` pins Go, which is why the CLI contract could not run before.

**`1223786` — record the browser flow and measure the overlay for real** (carries the completion trailer)
- The overlay overlap claim is now measured against a new full-size 1440×900 fixture, where **zero overlap is provable**; the thumbnail-sized case keeps the weaker compact-rail assertion, which is all that is true there.
- `SCREENOTE_EVIDENCE_DIR` records a Playwright trace per test plus named frames with the facts a picture can't show (resolved media paths, srcset candidates, component context, geometry). `script/attachment_browser_evidence` runs the suite and extracts ordered filmstrips.
- Gallery placeholder → warmed responsive thumbnails, the viewer's full control set against application media paths, and the composer's polite live region are now asserted rather than implied.

## Tests run

| Gate | Result |
|---|---|
| Full Rails suite | 1922 runs, 10471 assertions, **0 failures, 0 errors**, 61 skips |
| Lifecycle gate on SQLite | 156 runs, 2 skips (the server-database-only cases) |
| Lifecycle gate on PostgreSQL 17 | 156 runs, 601 assertions, **0 skips** |
| `s3` gate against MinIO | 7 runs, 74 assertions, 0 failures |
| `test/system/image_attachments_test.rb` | 21 runs, 347 assertions, 0 failures |
| `go test ./...`, `go vet ./...` | all packages ok |
| `bin/rubocop` (501 files), `bin/brakeman -q` | clean, 0 warnings |

## Two things I could not close

- **Video evidence.** `capybara-playwright-driver` resolves a recorded video path through a future that the page-close event *rejects*, so requesting one deadlocks the run with ffmpeg still holding the browser context — I reproduced this three ways before switching to Playwright traces (which carry the same screencast frames). The reason is recorded in the harness and `wiki/gaps.md`.
- **Rabata specifically.** The delivery contract runs against any configured S3 service and is proven against MinIO; pointing it at the production endpoint still needs operator credentials. The contract itself is no longer deferred. The screen-reader listen-through also stays manual, though the live region is now asserted by role, politeness, and exact text.

## Execute Output

I'll pause here and resume when the background evidence run reports; polling it further just competes for CPU with the browser suite.

## Execute Output

Worktree clean, one new commit. Summary of this continuation:

## What changed — commit `290f4a8`

All five review targets were evidence failures, not code defects: each promised proof existed only in principle. I made each one executable on an ordinary machine and then ran it.

**Browser video (`browser-attachment-authoring`).** The prior attempt's approach — passing `record_video_dir` to the browser context — is unusable, and I confirmed why: `capybara-playwright-driver`'s `reset!` asks the page for its video path *while the page is still open*, and `Playwright::Video#path` blocks on a future the page-close event rejects. The run hangs and leaves a zero-byte file. I removed that plumbing and instead encode from the trace screencast, which already covers a test's full length at ~20fps and stamps each frame with its capture millisecond, so `script/attachment_browser_evidence` produces a `<test>.webm` that replays at the run's real pace. Frame ordering also moved to the bare filename — the old `sort -t- -k2,2n` keyed on a hyphen in the enclosing path.

**Screenshots (`attachment-gallery-and-viewer`).** Extended the narrow-width claim to the viewer opened from the gallery (with a real overflow assertion, not just a frame) and captured both component contexts at 480px as well as desktop. Ten named frames now cover the placeholder, warmed responsive thumbnails under the annotation *and* the reply, the labeled viewer with its full control set on application media paths, both narrow widths, and both contexts.

**Object store (`deferred-storage-and-overlay-evidence`).** Added `script/attachment_object_store_qualification`, which provisions an ephemeral MinIO container on the same immutable image `container-s3` uses (or takes an operator's endpoint) and runs the `s3` gate. The delivery half no longer waits on anyone.

## Tests run

| Gate | Result |
|---|---|
| Browser evidence suite | 21 runs, 354 assertions, 0 failures, **0 skips** |
| Lifecycle on PostgreSQL 17 | 156 runs, 601 assertions, **0 skips** |
| Lifecycle on SQLite | 156 runs, 595 assertions, 2 skips (exactly the two server-DB-only cases) |
| S3 delivery vs MinIO | 7 runs, 74 assertions, 0 skips |
| `go test ./internal/screenote/...` | ok (uncached) |
| Full Rails suite | 1922 runs, 10471 assertions, 0 failures, 0 errors, 61 skips |
| rubocop / brakeman | 501 files clean / 0 warnings |

Two notes worth flagging. `go test ./...` fails bare because the repository's top-level `vendor/` is Ruby's and Go reads it as an inconsistent vendor tree; `GOFLAGS=-mod=mod` is required and is what `bin/ci` already uses — I documented that explicitly in `wiki/testing-and-ci.md` rather than changing the layout. And the screen-reader listen-through remains genuinely manual; the suite asserts the live region's role, politeness, and exact text from the DOM, and `wiki/gaps.md` records that a real listen-through is still uncovered.















































<!-- COMPLETE -->
