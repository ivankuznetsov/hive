---
title: Circuits JSON pre-dispatch errors keep their schema
date: 2026-08-11T15:45:00Z
tags: [circuits, json, cli, provider-routing]
---

Registered `hive circuits` with the CLI wrapper's JSON usage-error contracts.
Unknown options and excess positional arguments rejected before command
dispatch now emit a valid `hive-circuits.v1` error envelope instead of
unstructured Thor output.
