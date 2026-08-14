---
title: Remove the unused release asset archive-entry validator
date: 2026-08-13
tags: [release-candidate, assets, cleanup, testing]
---

Removed the uncalled `AssetVerifier#validate_archive_entries!` helper and its
sole unit assertion. `AssetVerifier` continues to verify cached regular files,
digests, and signed checksum bindings; live archive extraction safety remains
owned by the separate release archive and candidate-source readers. Updated
the testing inventory so it no longer attributes archive traversal coverage to
the asset-verifier test group.
