---
title: Keep the OpenCode offline smoke on the native executable
type: fix
date: 2026-08-27
tags: [agent-cli-runtime, opencode, testing, mise]
---

## Action

The installed-CLI offline smoke now considers every executable named
`opencode` in PATH and prefers a native executable over an earlier
package-manager launcher, including script and multicall-binary shims. An
explicit offline binary override still wins.

## Why

The first PATH entry on dogfood was a mise shell launcher. Probe environment
sanitization made that launcher reject its untrusted user configuration before
delegating `--version`, even though the native OpenCode binary later in PATH
satisfied the complete offline contract.

## Proof

A deterministic PATH fixture pins native-over-shim selection, and the real
installed-CLI smoke completes without an override or model request.
