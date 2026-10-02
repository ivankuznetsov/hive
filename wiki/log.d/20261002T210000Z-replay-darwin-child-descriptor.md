# 2026-10-02 — Inherit Darwin replay artifacts through a child descriptor

- Replay now duplicates the selected readable or executable descriptor onto a
  distinct child descriptor before spawning. This makes the macOS spawn action
  clear close-on-exec instead of performing a same-descriptor no-op, while the
  child alias remains bound to the pinned artifact identity.
- The portability fixture now models an opened alias handle correctly, and
  generated replay cleanup tolerates empty PID arrays under Bash 3.2 nounset.
