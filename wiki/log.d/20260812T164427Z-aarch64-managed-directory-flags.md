## [2026-08-12T16:44:27Z] storage — open managed directories on Linux aarch64

**Action:** Made the descriptor-backed managed-directory adapter select the
architecture-specific Linux `O_DIRECTORY` flag and added an exact aarch64
platform-contract regression.

**Why:** The x86_64 flag value is invalid on Linux aarch64, so authenticated
release upgrade and recovery migration failed closed while opening valid v4
attempt decision-index directories.
