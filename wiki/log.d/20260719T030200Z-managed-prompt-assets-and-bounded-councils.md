---
title: Harden managed inputs and add bounded council delivery
date: 2026-07-19
---

Managed package validation now rejects optional input names that can override
child process controls and validates manifest-bound prompt assets alongside
package tools. Managed prompts expose only absolute asset paths. Council
descriptors gained `on_max_rounds: wait|complete`; the default preserves the
operator wait, while `complete` lets a downstream delivery stage report an
explicit capped outcome.
