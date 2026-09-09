---
title: Preserve empty payloads during attempt finalization
tags: [attempts, runtime-control-plane, payload-store, daemon]
---

Attempt finalization can legitimately seal a zero-byte log or output. Reusing
the shared empty content address previously asked `IO#read` at EOF for one byte
and then called `bytesize` on its `nil` result, interrupting the daemon's loss
healer and leaving final attempts hot.

Sealed-payload verification now normalizes that EOF result to a binary empty
string before applying the existing size and SHA-256 checks. A regression test
proves the first empty seal, readback, and a second seal that reuses the same
content address.
