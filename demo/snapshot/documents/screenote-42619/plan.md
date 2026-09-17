---
title: Image Attachments for Native Screenote Messages
type: feature
date: 2026-08-17
origin: brainstorm.md
repository_snapshot: origin/main@e55fe2f
readiness: implementation_ready
---

## Overview

Add secure image attachments to Screenote's existing native browser annotation messages: the initial `Annotation#comment` composer and the `AnnotationComment` reply and reopen composers. The release includes picker, composer-scoped drop and paste, immediate per-file progress, retry, removal, optional alt text, atomic submission, protected thumbnails, an accessible viewer, bounded cleanup, REST/MCP/CLI annotation-detail metadata, and attachment metadata and parent links in the existing resolution digest.

This plan is implementation-ready. It does not create task, brainstorm, question, answer, generic messaging, browser-notification, export, audit, agent-history, or global-theme systems. The shared attachment component must render correctly in explicit light and dark component contexts; no application-wide theme switch is required.

### Repository-grounded direction

- Preserve `config.active_storage.draw_routes = false`. Application controllers stream bytes after live authorization and never expose or redirect to storage-provider URLs.
- Reuse the bounded streaming and decode properties of `Snapshots::AttachImage` through an attachment-specific service without changing screenshot policy.
- Stream and fully decode outside database locks. Serialize only aggregate checks and state transitions.
- Persist an attachment row in `uploading` state before streaming so claim can observe every in-flight or failed item. Prewarm tracked variants only after claim, never for drafts and never on GET.
- Browser authoring is session-only. REST, MCP, and CLI retain existing write contracts and receive attachment data on existing annotation-detail reads.
- Store stable identity and immutable metadata, never generated URLs. Generate protected URLs only while rendering or serializing an authorized read.

## Requirements Trace

| ID | Requirement | Bound coverage | Status |
| --- | --- | --- | --- |
| R1 | Every native browser composer | `Annotation#comment` root plus `AnnotationComment` reply/reopen, using shared behavior with layout variants | Ready |
| R2 | One parent, human uploader, inherited authorization, no public URL | Exclusive annotation/comment FKs, immutable uploader/project, live authorization on every byte request | Ready |
| R3 | Picker, drop, paste, previews, progress, alt text, remove, retry, submit blocking | Session draft endpoints and shared Stimulus controller | Ready |
| R4 | PNG/JPEG/WebP; 5 files; 20 MB each; 50 MB total; spoof/decode defenses | Bounded streaming, byte-derived detection, full decode, locked aggregate checks, claim recheck | Ready |
| R5 | Atomic association, immutable set, deletion cleanup | Transactional one-use batch claim, exclusive parent check, dependent destroy and reconciliation | Ready |
| R6 | Removal and bounded abandoned-draft cleanup | Idempotent remove, 24-hour expiry, registered recurring job, scheduler-independent byte cap | Ready |
| R7 | Responsive thumbnails and accessible viewer | Post-claim variants, protected delivery, modal dialog in explicit light/dark component contexts | Ready |
| R8 | Optional alt text and neutral fallback | Draft-only alt editing; immutable after claim; exact fallback `Attached image` | Ready |
| R9 | Existing non-browser reads and resolution digest | Canonical REST/MCP/CLI detail projection and digest metadata/protected parent link | Ready |
| R10 | Successful multi-image posting | Root, reply, and reopen end-to-end scenarios for picker/drop/paste | Ready |
| R11 | Invalid/pending/failed posting | Service, request, controller, and system failure/recovery coverage | Ready |
| R12 | Access, expiry, deletion, abandoned drafts | Separate draft/submitted authorization, token expiry, parent/account deletion, cleanup/reconciliation | Ready |
| R13 | Complete model/request/job/consumer/accessibility/responsive/theme coverage | Unit verification plus final cross-adapter and production-storage evidence | Ready |

## Scope Boundaries

### In scope

- Attachments on the annotation root composer and annotation reply/reopen composers only.
- PNG, JPEG, and WebP; at most 5 retained items, 20 MB each, and 50 MB total per message.
- Existing text requirements remain unchanged. Uploads supplement message text.
- Immediate upload, progress, preview, retry/remove, optional alt text, and blocking submit while any batch row is not ready.
- One isolated server-owned batch per mounted composer; public batch ID is also the one-use submission idempotency key.
- Immutable submitted attachment sets and metadata.
- Session preview routes, submitted browser media routes, bearer media routes, responsive galleries, and one modal-dialog viewer.
- Attachment arrays on the root annotation and every `comments[]` item in REST, MCP, and CLI detail reads.
- Root and latest pre-resolution reply attachment metadata in the existing resolution digest.
- Component-level light and dark styling and evidence without a global theme switch.
- Wiki pages and a `wiki/log.d/*-image-attachments.md` fragment during implementation.

### Explicitly out of scope

- Attachment authoring through REST, MCP, CLI, Telegram, or Hive-owned interfaces.
- Public Active Storage routes, provider redirects, permanent blob URLs, or stored signed URLs.
- Post-submission attachment or alt-text edits; captions; filename-derived labels; SVG, GIF, or HEIC.
- New task, brainstorm, question, answer, generic messaging, notification, export, audit, agent-history, or global-theme systems.
- Release, deployment, storage migration, or changes in the separate canonical public-CLI repository.

### Lifecycle and locking invariants

- A batch belongs to one human uploader and project, expires 24 hours after last activity, and transitions once from `open` to `claimed`.
- An attachment row is created as `uploading` before bytes stream, then becomes `ready` or `failed`; removed rows are terminal. Every batch row must be `ready` for claim.
- Every retained failed or uploading row occupies one of five slots. Retry reuses its client idempotency key.
- A draft attachment has a batch and neither parent FK. A submitted attachment has no batch and exactly one of `annotation_id` or `annotation_comment_id`; a database CHECK enforces exclusivity and FKs reject any other parent type.
- The uploader and project are immutable. Use an uploader FK with `ON DELETE RESTRICT`: account deletion must first destroy the user's annotation-owned content and explicitly purge or transfer no collaborator-owned attachment; if submitted attachments remain on another user's project content, account deletion is rejected with an actionable domain error. Test this path and never leave a missing uploader.
- Stream, size-check, and decode into a bounded tempfile without an Active Record lock. Serialize decode one file at a time per batch. If the global two-slot `ImageDecoding::Guard` is occupied by screenshot work, return retryable `decoder_busy`; do not mark a legitimate batch permanently failed.
- After validation, lock the batch, recheck open/expiry, 5-file and 50-MB totals, insert/transition the ready row, and bump expiry. Claim locks in the fixed order batch then attachment rows ordered by ID, rechecks all limits/states, creates the parent, moves rows to exactly one parent FK, and claims the batch in one transaction. Removal and cleanup use the same batch-then-ordered-attachments order.
- PostgreSQL supplies production row-lock semantics. SQLite tests cover constraints and deterministic interleavings; a PostgreSQL CI/release job must exercise aggregate races, lock ordering/deadlock absence, atomic claim, cleanup/remove/submit races, and constraint contracts.
- Rollback preserves ready drafts. Draft deletion, expiry, submitted-parent deletion, and reconciliation purge the primary blob, variant records, and derivative blobs through Rails lifecycle APIs.

## Implementation Units

### Unit 1 — Domain, constraints, ingest, and claim

**Goal:** Represent observable uploads, safe drafts, and immutable attachments for exactly the two existing parent models.

**Requirements:** R2, R4, R5, R6, R8, R12.

**Files:** migrations; `app/models/image_attachment_batch.rb`; `app/models/image_attachment.rb`; `app/models/annotation.rb`; `app/models/annotation_comment.rb`; new `app/services/image_attachments/ingest.rb` and `claim_batch.rb`; existing `snapshots/attach_image.rb` and `image_decoding/guard.rb` as precedents; model/service/constraint tests including `test/support/deterministic_concurrency_test_helper.rb`.

**Approach:**

1. Add unguessable batch public IDs, uploader/project FKs, state, activity/expiry timestamps, and a maximum of 6 simultaneously open batches per user. This is abuse headroom for three mounted composers and retries, not the per-message limit.
2. Add attachment state, client idempotency key, private Active Storage image, immutable metadata, batch FK, and exclusive nullable annotation/comment FKs with a CHECK matching the lifecycle invariant. Add dependent destroy to both allowed parents and reject any generic/polymorphic parent.
3. Set the uploader FK to restrict deletion and implement/test the account-deletion domain behavior described above.
4. Create the uploading row first. Stream at most 20 MB to a tempfile, derive media type from bytes, require declared/detected/extension agreement where a declaration exists, fully decode through the bounded guard, enforce dimensions/pixels, and generate the stored name server-side.
5. Decode outside locks, one at a time per batch; make contention with screenshot decoding retryable. Under the short batch lock, recheck aggregate limits and commit ready metadata/blob association.
6. Claim only when every persisted batch row is ready. Lock batch then ordered rows, revalidate ownership/membership/project/expiry/5/50 limits, create the parent, set exactly one parent FK, and mark the batch claimed atomically. Treat the public batch ID as the one-use submission key.

**Tests/verification:** Real and extensionless PNG/JPEG/WebP pass. SVG, GIF/animated GIF, HEIC, corruption, polyglots, spoofed declarations/extensions, excessive dimensions/pixels, sixth files, >20-MB files, and >50-MB batches fail. Cover idempotent retry, rollback recovery, immutable submissions, unsupported parent rejection, user deletion, and primary/variant purge. Run deterministic SQLite interleavings and the explicit PostgreSQL concurrency/constraint suite.

### Unit 2 — Session draft endpoints, authorization, and cleanup

**Goal:** Supply CSRF-protected browser APIs and bounded cleanup that remains safe if recurring execution is unhealthy.

**Requirements:** R2, R3, R4, R6, R11, R12.

**Files:** `config/routes.rb`; controllers under `app/controllers/image_attachment_drafts/`; cleanup and submitted-orphan reconciliation jobs; `config/recurring.yml`; startup/health registration check; request/job tests.

**Approach:**

1. Controllers inherit `ApplicationController`, retain `protect_from_forgery`, require the session principal, and scope every create/resume/upload/reconcile/alt/remove request through current membership. Stimulus sends `X-CSRF-Token` on every multipart or JSON request; tests reject session POST/PATCH/DELETE without it.
2. Return non-enumerating 404s for foreign IDs. Draft preview GET is authorized only for the uploading user, an open unexpired unclaimed batch, and current project membership. A same-project collaborator must receive 404 for a guessed sequential draft ID.
3. Return stable IDs, state, metadata, preview URL, expiry, machine code, and actionable text—never provider keys or URLs. Make remove and reconcile idempotent.
4. Schedule bounded cleanup in every deployed environment that runs application jobs (including self-hosted production configuration), document the interval, and assert at startup/health that the cleanup task is registered with the Solid Queue recurring supervisor. Deployment health fails visibly when it is absent.
5. Expire after 24 hours. Candidate scans are bounded; each job locks and rechecks eligibility using the global lock order. Add a per-user cap of 6 open batches and a scheduler-independent cap on total outstanding draft bytes; throttles by user and IP remain separate.
6. Add a bounded reconciliation job for submitted attachment rows whose allowed parent no longer resolves because callbacks were bypassed. Lock/recheck, purge primary and derivatives, record metrics, and alert on nonzero findings.

**Tests/verification:** Cover logged-out/suspended/removed-member/foreign/expired access, CSRF, sequential-ID draft privacy, response loss, abort/remove, rate/byte/batch caps, cleanup registration, overlap with claim, and cascade/delete-all orphan reconciliation in both no-wrong-purge and no-leak directions.

### Unit 3 — Root, reply, and reopen composer UX

**Goal:** Provide one state machine across the two composer locations while respecting their different geometry and validation contracts.

**Requirements:** R1, R3, R4, R8, R10, R11, R13.

**Files:** shared partials under `app/views/image_attachments/`; `image_attachment_composer_controller.js`; `annotorious_controller.js`; `annotation_controls_controller.js`; annotation form/annotation partials; application CSS; system tests.

**Approach:**

1. Mount one isolated batch/controller on the cloned Annotorious root form and each reply/reopen disclosure. Render the shared partial as a compact horizontal rail for the clamped overlay so it never covers the selected screenshot region, and as stacked rows beneath the textarea in the sticky sidebar.
2. Route picker input through one enqueue function. Bind image drop/paste only to the composer form surface: screenshot canvas drag remains Annotorious drawing; text-only paste inserts text; mixed clipboard input both inserts text and attaches images.
3. Show per-file progress, preview, retry, remove, optional alt text, announced status, and specific errors. Disable submit while any persisted batch row is uploading/failed or while local reconciliation is pending.
4. Submit root, reply, and reopen with Stimulus `fetch` and CSRF. On 422 JSON, keep the overlay/disclosure mounted and restore body, coordinates, batch public ID, and ready attachment IDs; render field errors without redirecting. On success, follow the existing navigation/update contract.
5. Treat Annotorious `cancelForm` and Turbo disconnect/navigation as client disconnect only; leave committed drafts for 24-hour expiry. Reconnect must not duplicate listeners, requests, or previews.

**Tests/verification:** For root/reply/reopen, cover picker/drop/paste, mixed/text paste, canvas drawing, concurrent composers, cancel/reconnect, progress, failure/retry/remove, 5/20/50 limits, neutral labels, keyboard use, narrow/desktop layouts, and explicit component light/dark contexts. Verify overlong reply body and reopen-when-not-resolved return 422 and preserve body/batch; manually smoke-test announcements.

### Unit 4 — Parent submission and deletion lifecycle

**Goal:** Bind ready batches atomically while preserving user input on every ordinary validation failure.

**Requirements:** R1, R2, R5, R10, R11, R12.

**Files:** `annotations_controller.rb`; `annotation_comments_controller.rb`; both parent models; `claim_batch.rb`; controller/lifecycle tests.

**Approach:**

1. Accept only a single batch public ID in each form. Ignore any client-supplied uploader, project, size, type, attachment IDs, state, or parent fields.
2. Change both create endpoints, including reopen, to support the Stimulus JSON contract: success identifies the existing/created parent; ordinary invalid text, invalid state, or invalid batch returns 422 with body/coordinates/batch/ready-ID rehydration data. Explicitly convert reopen-when-not-resolved from an unhandled/redirect path to this 422 contract.
3. Claim with the Unit 1 transaction and lock order. Double click, concurrent tab, or response-loss retry with the same batch public ID returns the already-created parent.
4. Parent destroys remove attachment rows and schedule complete blob/variant purge. Reconciliation covers database cascades or future callback-bypassing deletion.

**Tests/verification:** Cover successful root/reply/reopen, overlong text, invalid reopen state, pending/failed/foreign/expired/partially removed/cross-composer batches, response-loss retry, concurrent remove/cleanup/submit, account and parent deletion, and unchanged attachment-free API/MCP/CLI authoring.

### Unit 5 — Private media, variants, gallery, and viewer

**Goal:** Deliver drafts and submitted images without ID collisions, decode-on-GET, or authorization leaks.

**Requirements:** R2, R7, R8, R10, R12, R13.

**Files:** image attachment gallery partials; a dedicated `ImageAttachmentMediaController`; `config/routes.rb`; viewer Stimulus controller; CSS; thumbnail jobs/services; delivery/job/system tests. Keep `MediaController` and `media/screenshot_images/:id/:variant` unchanged.

**Approach:**

1. Add the session route `media/image_attachments/:id/:variant` with allowlisted thumbnail/original/download variants and disposition. Draft requests use uploader+unexpired-batch authorization; submitted requests recheck live parent/project membership. Both return private non-enumerating failures.
2. After claim, enqueue tracked bounded 1x/2x variants. Never prewarm drafts. GET never invokes libvips; pending work uses a stable placeholder. Reconciliation is idempotent/generation-aware and all deletion paths purge derivative records/blobs.
3. Preserve `private, no-store`, `nosniff`, safe dispositions, and supported byte ranges. Never redirect to backing storage.
4. Render stored dimensions and author alt text or exact fallback `Attached image`. Use one labeled modal-dialog pattern with initial focus, focus containment/restoration, Escape, arrow navigation, bounded zoom, download, and open-original. Hide previous/next for a one-image gallery.

**Tests/verification:** Cover draft owner versus collaborator, submitted live authorization and revocation, expiry/deletion, invalid variants/IDs, safe headers/dispositions, no provider location, no GET decode, variant retry/purge, keyboard/focus/zoom, single/multiple images, responsive overflow, and explicit light/dark contexts.

### Unit 6 — REST, MCP, CLI, digest, and documentation

**Goal:** Preserve shipped read contracts while adding the same attachment object everywhere existing annotation details are consumed.

**Requirements:** R2, R8, R9, R12, R13.

**Files:** REST contract serializer/scope/controller; bearer attachment-media controller/route and principal services; MCP tools; Go types/client/CLI and tests; digest job/mailer/template; affected wiki pages and log fragment.

**Approach:**

1. Define `attachments` as an always-present array on the root annotation and every `comments[]` item. Each object contains `id`, `alt_text`, `media_type`, `width`, `height`, `size`, `url`, and `url_expires_at`; omit storage keys and semantic filenames.
2. Eager-load attachment rows/blobs for detail reads. Generate URLs only after authorized detail access; lists remain metadata-light where they do not already expose messages.
3. Capture the shipped MCP `get_annotation` response as a golden fixture. Preserve `screenshot_status`, `cropped_image_base64`, `mime_type`, and each comment's `id`, `action`, `body`, `author`, and `created_at`; add `attachments` without renaming, dropping, or nesting existing keys. REST is canonical for the new attachment object, not a license to replace the MCP envelope. Update Go `Comment` and root types accordingly.
4. Mint bearer media URLs with `generates_token_for :image_attachment_media, expires_in: 5.minutes`. Require an OAuth/API-key `Authorization` bearer principal plus the unexpired purpose token and then live project/parent authorization. A token alone is never sufficient. `url_expires_at` reflects the five-minute expiry.
5. Keep all non-browser write schemas unchanged and return canonical empty attachment arrays where relevant.
6. For each resolution digest item, load metadata for the resolved annotation's root attachments and for the latest pre-resolution reply already used as `reply_text`. Set the CTA to `page_workspace_path_for(screenshot, viewport: annotation.viewport)#<dom_id(annotation)>`; never embed a blob URL.
7. Update the wiki and principal/action table for browser-only authoring, common authorized reads, both allowed parents, routes, lifecycle, and absent future products.

**Tests/verification:** Snapshot REST/MCP/CLI root and comment arrays; compare against the pre-change MCP golden fixture; cover OAuth/API-key scope and revocation, token-only rejection, exact five-minute expiry/refresh, empty arrays, digest selection/deep link, no durable URLs, and query counts.

## Verification Contract

Execution evidence must include:

1. Focused tests for each unit, followed by all repository Rails and Go test/lint gates.
2. SQLite model/request/constraint and deterministic interleaving tests plus a PostgreSQL-adapter job for locks, constraints, aggregate races, lock ordering, atomic claim, and cleanup/remove/submit races.
3. Root, reply, and reopen browser evidence for picker, composer-scoped drop/paste, mixed paste, upload/failure/retry/remove, 422 preservation, pending thumbnail, gallery, modal, zoom, download, and original-open at desktop and narrow widths.
4. Keyboard-only composer/viewer evidence, manual screen-reader announcement smoke, and explicit component light- and dark-context screenshots. No global theme switch is part of acceptance.
5. Draft-owner and submitted-parent authorization matrices, CSRF rejection, default Active Storage route absence, no-provider-redirect evidence, five-minute bearer-token expiry, and live revocation.
6. Unit tests may prove application route/header/token policy with Disk storage. Before release, run a production-service-configured Rabata S3 check (or explicit S3 test service) proving the application streams without provider redirects/presigned locations and that expired URLs fail; Disk-only evidence is insufficient.
7. Lifecycle evidence in both directions: races cannot exceed limits, partially claim, or purge another message; expiry, parent cascade/callback bypass, and account deletion cannot leak primary or derivative blobs.
8. REST/MCP/CLI golden payloads proving the canonical attachment object on the root and every comment while preserving shipped MCP keys.
9. Digest evidence proving the exact root/latest-reply attachment selection and viewport/annotation deep link without a blob URL.
10. Deployment evidence that recurring cleanup is registered/healthy in each supported job-running environment and scheduler-independent open-batch/outstanding-byte caps fail closed.

## Risks

| Risk | Mitigation |
| --- | --- |
| SQLite green tests mask PostgreSQL locking defects | Fixed lock order plus mandatory PostgreSQL race/constraint job |
| Streaming/decode holds locks or decoder contention rejects normal multi-file selection | Decode outside locks, serialize per batch, short transition locks, retryable global-guard contention |
| Draft previews leak because no parent exists | Uploader+open/unexpired-batch authorization and non-enumerating tests against collaborators |
| Redirect-only controller behavior loses overlay/sidebar input | Fetch/422 response contract and mounted-state rehydration for root/reply/reopen |
| Cleanup supervisor is absent | Registration health check, supported-environment schedule, byte and six-batch caps |
| Callback-bypassing deletes leak submitted blobs/variants | Bounded orphan reconciliation, metrics/alert, leak-direction tests |
| Prewarming drafts amplifies decode/storage work | Enqueue variants only after claim and purge all derivatives |
| Uploader deletion violates immutable identity/FK | Restrictive FK, explicit domain error/lifecycle, user-destroy tests |
| S3 behavior is falsely inferred from Disk tests | Required Rabata/S3-configured redirect and expiry evidence |
| MCP canonicalization breaks existing agents | Pre-change golden fixture; preserve envelope/comment keys and add arrays only |
| Capability token is mistaken for authority | Five-minute purpose token plus bearer principal plus live parent authorization |
| Overlay rail covers selection or sidebar overflows | Separate horizontal overlay and stacked sidebar variants with responsive evidence |
| Paste/drop steals text or Annotorious drawing | Composer-only listeners; preserve text/mixed paste and canvas drag behavior |
| Missing product domains expand scope | Bind only Annotation/AnnotationComment and existing consumers; exclusive FKs prevent future parent types |

## Sources and Research

### Repository evidence

- Composer and response behavior: `app/models/annotation.rb`, `app/models/annotation_comment.rb`, annotation views/controllers, `annotorious_controller.js`, and `annotation_controls_controller.js`.
- Storage, decode, and delivery: `config/application.rb`, `config/storage.yml`, `config/database.yml`, `media_controller.rb`, `screenshot_image.rb`, `snapshots/attach_image.rb`, `image_decoding/guard.rb`, thumbnail jobs, and authorized-media tests.
- Consumers/auth: REST serializer/scope, authenticated principal and bearer services, `get_annotation_tool.rb`, Go types/client, and principal contract tests.
- Lifecycle/digest: `config/recurring.yml`, deployment surfaces, digest job, notification mailer, and database cascade definitions.

### External primary guidance

- Rails Active Storage overview: private service access, authenticated controllers, progress, and cleanup — <https://guides.rubyonrails.org/active_storage_overview.html>
- OWASP File Upload Cheat Sheet: allowlists, content validation, generated names, authorization, and limits — <https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html>
- WAI-ARIA modal dialog pattern: focus, contained tab sequence, Escape, labeling, and restoration — <https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/>

<!-- COMPLETE -->
