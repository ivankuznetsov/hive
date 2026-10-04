# 2026-10-02 — Launch Darwin native replay after descriptor inheritance

- Hosted macOS rejected native replay through both duplicated and original
  parent-process `O_EXEC` aliases, even when the selected handle was made
  inheritable before Ruby spawned it.
- Native replay now starts fixed `/bin/bash -p`, maps the pinned executable
  descriptor onto child fd 9 (or 8), and immediately replaces the trampoline
  through the child alias with `argv[0]` set to `repro.sh`.
- Privileged Bash ignores startup hooks such as `BASH_ENV` for the trampoline
  but passes the original environment to the replay artifact. Hosted macOS
  evidence for this correction remains outstanding.
