# Release and handoff artifacts

- Pull request: [#21](https://github.com/ivankuznetsov/agent-plugins/pull/21), opened as a draft from `migrate-every-agent-plugin-to-260709-3082` at commit `6ab2d95`.
- Delivery: seven reviewed commits implement the surface contract, deterministic package generation, canonical workflows, Screenote CLI migration, security coverage, native-discovery CI, and release documentation.
- User-facing result: all five shipped plugins have Claude Code, Codex, Pi, and OpenClaw packages; Screenote now uses the allowlisted OAuth-first JSON CLI contract with no MCP fallback.
- Review result: pass 01 produced no reviewer findings or escalations. The worktree was clean at artifact collection.
- Verification carried forward from execution: inventory validation, deterministic-generation checks, 37 offline tests, Screenote lint/security checks, and isolated native discovery across all five plugins and four supported hosts passed.
- Release caveat: Screenote's first tagged OAuth-first CLI minimum is not yet known, so compatibility remains pinned to the recorded public merge commit until a containing release exists.
- Visual evidence: the change has a CLI surface and was classified as `tui`, but capture could not be produced because neither `asciinema` nor `vhs` is installed. This non-blocking capture failure is recorded in `media/manifest.json`; no PNG or GIF was created. Screenote upload was also unavailable because Screenote is not connected.
- No additional concrete release artifacts were produced beyond the PR handoff and required media manifest.

<!-- COMPLETE -->
