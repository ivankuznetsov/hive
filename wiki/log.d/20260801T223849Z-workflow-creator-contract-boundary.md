---
title: Isolate the mutation-free workflow creator proof contract
type: change
created: 2026-08-01
tags: [openclaw, workflow-creator, proof, attestation, architecture]
---

- Extracted the creator vocabulary, exact document validator, read-only bundle
  custody, declarative execution-summary validator, and shared proof primitives
  from the monolithic live-agent proof file.
- Attestor now accepts only an owner-private four-file canonical bundle, retains
  its validated bytes through the existing output assembly, and Verifier uses
  the same contract after source installation roots disappear.
- The schema-v1 creator row cross-binds installed candidate/OpenClaw closure
  manifests, the authored/executed instruction, exact command and prompt
  digests, classification, and one execution receipt. Missing, extra,
  wrong-type, substituted, noncanonical, or secret-shaped data fails closed.
- Added the typed, bounded, secret-safe non-passing row that downstream
  publication and live orchestration will persist before preflight.
- Added no publication or runtime compatibility path: the old single-file
  producer is intentionally rejected, and the live lane remains non-claiming
  until U1b, U14, and U15 supply the composed path.
- Added the validator-only component row, exact builder-source closure, focused
  mutation/custody/cross-binding tests, and the explicit downstream gap.
- Resolution 01 hardened that boundary after three independent review lenses:
  recursively canonical object keys while preserving array order, strict
  integer fields, exact created-file order, one public facade, bounded
  descriptor-first no-follow/nonblocking custody, and an attestation-required
  retained path.
- Installed manifests now bind a complete ordered inventory, unique required
  roles, candidate version, package identity, total size, and closure digest.
  The execution receipt now records two ordered outer model loops, all nine
  positioned commands, the candidate gateway, two policy-bound archives,
  bounded captures, per-process custody, run correlation, containment,
  aggregate teardown, and identity-checked cleanup.
- Candidate source verification rejects aliases, case collisions, duplicates,
  and links throughout the protected builder closure. Adversarial tests cover
  raw key reorder, ordered-array drift, floats, missing attestation rows, FIFOs,
  oversized source/retained directories, closure drift, and receipt mutation.
