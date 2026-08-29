---
title: Bind Patrol rework to review feedback and effective progress
type: fix
date: 2026-08-27
tags: [patrol-fix, rework, review, receipts]
---

## Action

Patrol Fix now places the exact prior Review decision referenced by the reopen
receipt into the rework agent's untrusted context. Before a new Fix receipt
becomes durable, the controller rejects a run whose diff and structured
validation commands are both unchanged from Review's referenced Fix receipt.

## Recovery

A no-op remains in the current Fix generation with its owned worktree intact and
no new Fix receipt. Rework may still keep the same patch when it corrects the
validation-command plan.

## Proof

The transition regression covers feedback propagation, unchanged rework
rejection, and validation-plan-only progress.
