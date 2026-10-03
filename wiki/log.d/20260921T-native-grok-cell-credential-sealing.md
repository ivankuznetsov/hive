# Native Grok benchmark credential sealing

- Native Grok benchmark cells now receive a read-only copy of the host login and a writable per-cell tmpfs credential path.
- Grok refresh locks and auth rotations stay inside the container; stale or root-owned host `auth.json.lock` files no longer block or mutate the shared login.
- The focused bench workflow suite passes (`53 runs, 534 assertions`).
