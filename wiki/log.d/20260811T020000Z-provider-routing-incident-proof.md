---
date: 2026-08-11
title: Prove provider-route fallback through durable recovery
---

- Activated the hermetic `provider-limit-retry` incident. It opens only the
  selected provider-account circuit from a trusted transport envelope, waits
  for provider-health acknowledgement, and proves one charged
  `RecoveryCoordinator` successor selects the next configured route.
- Routed execution failures now replace attempt custody with a bounded
  `provider_route_failed` marker before propagating to the supervisor, so
  daemon recovery never observes stale `AGENT_WORKING` state.
- Recovery successors retain the predecessor's frozen routing generation while
  fencing execution against the exact post-clear progress token. Their durable
  attempt charge now mirrors the recovery request's retry count.
- Kept the extracted `agent-cli-runtime` observable-result value in additive
  parity with Hive's optional normalized provider signal; classification and
  health policy remain outside the component.
- Made the sanitized external capture fixtures independent of Ruby 3.4's
  non-default `base64` gem so the final full-suite proof remains hermetic after
  Hive intentionally removes ambient gem paths.
- Promoted `recovery.provider_limit` to required release coverage. Three
  unrelated incident fixtures remain explicitly pending behind their own
  sibling contracts.
