---
date: 2026-11-07
title: Scoped remote API reads and opaque evidence identities
---

Added bearer-authorized semantic status/task/question/log/diff/artifact reads
under `/api/v1`. DTO allowlists exclude native paths and raw command lines;
project authorization precedes resolution and aggregate status scans. Status
cursors bind the allowed project registrations and task snapshot. Question
handles retain original native bindings only in an owner-only server registry;
artifact IDs bind target/incarnation observations and reference only declared
workflow files. These read identities carry no command receipt authority.

Bounds apply to complete escaped JSON: 100 tasks/2 MiB for status, 256 KiB for
logs and 512 KiB for individual artifacts/diffs, preserving native manifest
limits. Unknown base versions return typed `unsupported_version` before body
parsing; unknown v1 targets remain uniform JSON 404. Bounded API responses are
closed before fixed-field audit logging to discard Rails request ID tags.
