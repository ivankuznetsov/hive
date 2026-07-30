---
title: Harden workflow-creator evidence admission after adversarial review
type: fix
created: 2026-07-30
tags: [agent-skills, openclaw, evidence, security, architecture]
---

- Sanitized exact credentials before bounding failure detail so an uploaded
  receipt cannot retain a truncated credential prefix while claiming a passed
  scan.
- Routed the creator primary through the same bounded, owner-private,
  regular-file, no-follow reader as its supporting bundle before parsing.
- Rejected dot and NUL installed-file paths, normalized malformed contract
  values to the proof error surface, and added focused inventory-limit cases.
- Preserved authenticated model-loop progress in later non-passing failures and
  moved every success-closure check before atomic primary publication.
- Kept exact execution custody and live provider orchestration open in
  [[gaps]]; this hardening does not turn the U1 foundation into a passing
  protected-main proof.
