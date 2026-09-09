---
title: Cutover accepts hardlinked task artifacts
type: fix
date: 2026-08-31
---

The irreversible fleet cutover now fingerprints regular task files even when
they have multiple hardlinks. Archived tasks can legitimately retain build or
capture outputs produced this way; cutover reads and preserves those bytes and
does not need exclusive inode ownership. Symlinks, oversized files, and
non-regular entries remain fail-closed, and unsafe-entry errors now identify
the exact path.
