---
title: Contain workflow presentation failures
type: fixed
module: workflows
tags: [workflows, web, digest]
---

Digest project-source construction and Web workflow rendering now contain
project configuration, YAML, and I/O failures at their source boundaries.
Unavailable descriptors retain diagnostic warnings, built-in terminal-stage
recognition, and useful unknown-workflow messages without aborting healthy
projects or task pages.
