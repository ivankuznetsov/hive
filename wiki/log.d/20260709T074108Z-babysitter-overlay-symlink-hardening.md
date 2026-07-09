---
ts: 2026-07-09T07:41:08Z
area: babysitter
---

**Action:** Hardened `Hive::Babysitter::DryRunEnv` overlay setup so dry-run wrapper generation no longer follows a pre-existing `.hive-babysitter-dry-run-bin` symlink. The setup now `lstat`s and removes any existing overlay path, creates a fresh owned `0700` directory, and verifies it before writing `git` / `gh` launchers.

**Coverage:** Added `test_with_env_replaces_preexisting_overlay_symlink_before_writing_wrappers`, which pre-creates the overlay name as a symlink to a temp directory and verifies wrapper files are not written through it.
