---
title: Pin UTF-8 in the macOS release-candidate sandbox
type: change
module: release-candidate
created: 2026-08-06
tags: [release-candidate, workflow, macos, sandbox, encoding]
---

The macOS release-candidate sandbox now fixes `LANG` and `LC_ALL` to
`en_US.UTF-8`. Installed baseline and candidate commands therefore retain a
deterministic UTF-8 external encoding after the host environment is scrubbed,
instead of falling back to US-ASCII while reading project configuration.

The ordinary install-smoke workflow exercises the same environment and fails
unless Ruby reports UTF-8 as its default external encoding, keeping this hosted
runtime prerequisite visible on pull requests.
