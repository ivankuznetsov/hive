---
title: Installed Patrol qualification uses a host-owned provider broker
type: architecture
date: 2026-07-31
tags: [patrol, qualification, provider, sandbox]
---

The compressed installed Patrol lane now executes the packaged `hive-cli` gem
as both its runtime and candidate source instead of reading module code from
the source checkout. Native Patrol packages ship in the gem, and the candidate
mount exposes only that exact package plus the installed dependency closure.

Live review calls cross one generation-scoped Unix socket into a host-owned
broker. The broker fixes the OpenRouter endpoint and
`openai/gpt-5.6-terra`, holds the only credential, verifies PID-reuse-safe
launcher ancestry, permits one bounded call, writes canonical output through
managed no-follow custody, and binds a secret-free transcript digest into the
process-generation receipt. Retryable provider conditions retain their exact
closed reason outside the immutable terminal lane.

A real Bubblewrap test runs the packaged provider client against the broker
while proving that TCP, the source checkout, provider credential, and model
identity are absent from the candidate. This does not replace the still-open
authenticated installed-current-main run or later-candidate protected-control
proof.

The component catalog also names the qualification-only Architecture Patrol
composition root that drives the real `JobStore` and intake facade inside its
isolated candidate state tree; production construction sites remain otherwise
closed. The host evidence collector reads bounded raw job and occurrence
records through pure validators, rather than constructing either live product
store while observing terminal evidence. The catalog also records the closed
qualification-only Attempts composition: the candidate drives the real
dispatcher, launcher, store, and reconciler, while host observers are scan-only
and host supervisors share the PID-reuse-safe identity verifier. Broker sealing
removes the generation capability even when transcript verification fails, and
lane artifact assembly rejects duplicate case-generation transcript identities.
Direct qualification-driver tests now bind token accounting to each scenario
sandbox, and module-decision fault recovery waits for the deliberately gated
wrapper and worker to exit before requiring one exact lost-attempt transition.
