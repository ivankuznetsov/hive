## Round 1
### Q1. What is the authoritative migration inventory: every directory in the repository, every entry in marketplace metadata, or another explicit list—and are experimental, deprecated, or private plugins included?
### A1.
The authoritative inventory is every plugin registered in either marketplace plus every non-deprecated directory under `plugins/`. Include experimental public plugins but label their stability; exclude fixtures, eval-only packages, archived/deprecated plugins, and anything not shipped from this repository. CI must fail when marketplace and directory inventories drift.

### Q2. For each agent, what must count as a first-class surface beyond an install path and a discoverable invocation (for example, native metadata, commands, shared resources, or lifecycle hooks), and which minimum supported versions of Claude Code, Codex, Pi, and OpenClaw should validation target?
### A2.
First-class means native install metadata, a discoverable SKILL.md/invocation, required bundled resources/scripts, and lifecycle/config guidance where the platform supports it. Target the current released versions used in CI and document minimum versions discovered from their manifest/skill specifications; do not invent unsupported version guarantees.

### Q3. Must existing plugin names, skill names, command names, arguments, and documented user flows remain backward-compatible on Claude and Codex? If exceptions are allowed, which ones may change?
### A3.
Preserve existing Claude and Codex plugin/skill/command names, arguments, and user flows except Screenote authentication/setup, which intentionally migrates from MCP to CLI. Keep aliases or migration errors for renamed legacy entry points, but do not retain an MCP execution fallback.

### Q4. What should be the canonical source and adapter policy: generated platform packages checked into the repository, thin checked-in wrappers that reference a shared skill, or another model? Must installs work from a copied package where symlinks and repository-relative paths are unavailable?
### A4.
Maintain one canonical skill body and generate checked-in platform packages/adapters from it, with small explicitly marked platform-specific overlays. Generated packages must be self-contained after installation: no symlinks and no dependency on repository-relative paths outside the plugin package. CI regenerates and fails on diff.

### Q5. Should the repository install or pin the Screenote CLI, merely declare it as a prerequisite, or detect it and provide installation guidance? Which released version or commit containing PR #37 is the compatibility baseline?
### A5.
Declare Screenote CLI as a prerequisite, detect its executable and compatible command contract, and provide installation/login guidance; do not silently install binaries. Baseline is the first released CLI containing merged PR #37. Until tagged, test against the merged main commit and make the baseline easy to advance.

### Q6. What exact safety rules must the `screenote`, `snapshot`, and `feedback` skills preserve around capture and upload—for example, user confirmation boundaries, allowed URLs, local-file handling, overwrite behavior, and whether a failed upload retains or deletes a local capture?
### A6.
Preserve explicit user intent for captures/uploads, restrict browser capture to user-specified or locally discovered HTTP(S) targets, use secure temporary directories, never interpolate untrusted values into shell, refuse unexpected local-file paths/overwrites, and retain a failed local capture long enough to report its path for recovery. Delete successful temporary captures unless the user requested retention.

### Q7. When Screenote authentication or project resolution fails, what observable behavior is required for interactive and noninteractive runs: exit status, retry/login guidance, project choices, and the precedence of `--project`, `SCREENOTE_PROJECT`, and config? How should ambiguous or inaccessible projects be reported?
### A7.
Pass through and explain the CLI's machine-readable errors: missing token/project exits 2, invalid/expired token exits 3, and other nonzero results stop the skill. Interactive runs may suggest `screenote login` and list/select accessible projects; noninteractive runs never prompt or open a browser and require `SCREENOTE_TOKEN` plus project selection. Preserve precedence `--project` > `SCREENOTE_PROJECT` > config; ambiguous/inaccessible projects produce a JSON-backed actionable error without guessing.

### Q8. What is the token-redaction acceptance rule: is it sufficient that skills never deliberately echo tokens, or must tests prove that tokens are absent from command traces, captured stdout/stderr, generated artifacts, snapshots, and error diagnostics as well?
### A8.
Tests must prove sentinel tokens are absent from rendered commands, stdout/stderr excerpts, logs/traces, generated artifacts, snapshots, caches, and diagnostics. Skills must pass tokens only through the CLI's supported environment/config/auth mechanisms and must never place them in arguments or prose.

### Q9. How much behavior must CI exercise on each agent: structural validation only, native loading/discovery smoke tests, invocation/evals with mocked CLI JSON, or real noninteractive Screenote integration tests using secrets? Which checks are required to block a merge?
### A9.
Merge-blocking CI includes structural/manifest validation for every platform, native discovery/loading smoke tests where CLIs are available, generated-adapter drift checks, and mocked Screenote CLI JSON scenarios for success and every auth/project error. Add one opt-in real Screenote integration job using protected secrets; it should not block ordinary forks.

### Q10. Should adapter-divergence tests require byte/semantic equivalence to the canonical source, or only verify required sections and references? What platform-specific deviations are intentionally permitted?
### A10.
Require semantic equivalence to canonical sections and resources, verified by generation hashes/normalized AST-like checks rather than raw byte identity. Permit only declared platform overlays for invocation syntax, metadata/frontmatter, tool names, and installation paths; behavioral requirements and safety rules may not diverge.

### Q11. What documentation and marketplace outcomes define completion: one repository-wide compatibility matrix, per-plugin install/use instructions for all four agents, automated marketplace metadata generation, migration notes, and/or deprecation guidance for the removed MCP setup?
### A11.
Completion requires a repository compatibility matrix, per-plugin install and invocation instructions for Claude/Codex/Pi/OpenClaw, generated marketplace/manifests where applicable, Screenote CLI setup/login/noninteractive examples, and explicit MCP removal/migration notes. Automated checks must prove every shipped plugin has all four surfaces or an explicitly approved unsupported declaration.

### Q12. Is changing the Screenote CLI or upstream agent tooling in scope if the required JSON/auth behavior is incomplete, or must this project consume those tools as fixed external dependencies and document any blockers?
### A12.
Treat Screenote and agent CLIs as external dependencies. If the merged contract is incomplete, record a precise upstream blocker and add a compatibility test; do not broaden this task into upstream implementation unless a minimal fix is necessary and separately reviewed.

## Requirements

### Actors

- Plugin users install and invoke shipped skills natively from Claude Code, Codex, Pi, or OpenClaw without repository-relative dependencies or symlinks.
- Screenote users authenticate interactively with `screenote login` or noninteractively through supported token/config mechanisms, then select a project explicitly or by configured precedence.
- Plugin maintainers generate, validate, document, and release equivalent agent packages from one canonical skill body plus declared platform overlays.
- CI/release maintainers enforce inventory completeness, adapter parity, secret redaction, native discovery, and Screenote CLI behavior before merge.

### Flow

- Define the shipped inventory as every plugin registered in either marketplace plus every non-deprecated directory under `plugins/`; include public experimental plugins with stability labels and exclude fixtures, eval-only, archived/deprecated, private, and otherwise unshipped packages.
- Preserve existing Claude and Codex names, arguments, commands, and user flows except for Screenote's intentional MCP-to-CLI authentication/setup migration; legacy renames receive aliases or migration errors, never an MCP fallback.
- Package every shipped plugin with native install metadata, a discoverable `SKILL.md`/invocation, bundled resources or scripts, and lifecycle/config guidance where supported for Claude Code, Codex, Pi, and OpenClaw.
- Generate checked-in, self-contained agent packages from one canonical skill body with only declared overlays for invocation syntax, metadata/frontmatter, tool names, and install paths; behavioral and safety requirements remain common.
- Make the Screenote CLI a detected prerequisite rather than silently installing it. Target the first release containing PR #37, use the merged main commit until then, and keep the compatibility baseline easy to advance.
- Implement Screenote flows solely through the machine-readable JSON commands `project list`, `page list`, `screenshot list/create`, `annotation list/get`, and `comment add`; remove obsolete `.mcp.json` wiring after confirming no skill references it.
- Resolve Screenote projects in the order `--project` > `SCREENOTE_PROJECT` > config. Interactive flows may suggest login and accessible projects; noninteractive flows never prompt or launch a browser and require `SCREENOTE_TOKEN` plus project selection.
- Preserve capture/upload safety: require explicit intent, capture only user-specified or locally discovered HTTP(S) targets, use secure temporary storage, avoid shell interpolation of untrusted values, refuse unexpected local paths/overwrites, retain failed captures for recovery, and delete successful temporary captures unless retention was requested.
- Pass tokens only through supported environment/config/auth channels and never place them in arguments, rendered commands, prose, output excerpts, logs, traces, artifacts, snapshots, caches, or diagnostics.
- Treat Screenote and agent CLIs as external dependencies. Record precise upstream blockers and compatibility tests when their contracts are incomplete; any minimal upstream fix requires separate review.
- Document minimum platform versions discovered from current manifest/skill specifications, per-plugin install and invocation paths for all four agents, a repository compatibility matrix, Screenote interactive/noninteractive setup, and MCP removal/migration guidance.

### Acceptance examples

- Given a marketplace entry or non-deprecated shipped plugin directory, validation finds explicit Claude Code, Codex, Pi, and OpenClaw surfaces; an absent surface is allowed only through an explicitly approved unsupported declaration.
- Given the filesystem and both marketplace inventories, CI fails when registrations, shipped directories, or generated marketplace/manifests drift.
- Given a clean checkout, regeneration produces no diff, all referenced skill files/resources resolve inside each package, and normalized generation hashes/semantic checks show canonical parity except for declared overlays.
- Given each available agent CLI, native loading/discovery smoke tests find the installed plugin and its skill invocation; validation targets current CI releases and documents spec-derived minimums.
- Given mocked successful Screenote JSON, the three Screenote skills invoke only the approved CLI command contract and complete without accessing MCP or `.mcp.json`.
- Given `missing_token`/`missing_project`, the skill stops with exit 2 and actionable JSON-backed guidance; given `invalid_token` or an expired token, it stops with exit 3; any other nonzero CLI result also stops processing.
- Given ambiguous or inaccessible project selection, the skill reports an actionable JSON-backed error without guessing; given multiple selection sources, it honors `--project`, then `SCREENOTE_PROJECT`, then config.
- Given a noninteractive run with `SCREENOTE_TOKEN` and a valid project selection, the flow succeeds without prompting or opening a browser; a protected-secret real integration job verifies this optionally without blocking ordinary forks.
- Given sentinel credentials across success and failure scenarios, merge-blocking tests find no token in commands, stdout/stderr excerpts, logs/traces, generated artifacts, snapshots, caches, or diagnostics.
- Given a failed upload, the skill reports the recoverable local capture path; given a successful upload, it removes the temporary capture unless the user requested retention.
- Given existing Claude/Codex entry points, compatibility tests retain their names, arguments, and flows apart from the documented Screenote setup change, and no hidden MCP fallback remains.

<!-- COMPLETE -->
