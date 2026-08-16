## 2026-08-16 — Run bounded managed actors through Pi

**Problem:** A reviewed Honeycomb actor mapped to Pi failed before launch because
Hive had no portable enforcement adapter for Pi, blocking OpenRouter-backed
review councils despite valid model routing and credentials.

**Fix:** Added a bubblewrap-backed Pi adapter. It mounts only descriptor-declared
read roots, the immutable Pi runtime, and the Pi auth file; supplies a disposable
home; maps Hive's read-only tools to Pi's `read`, `ls`, `grep`, and `find`; disables
extension, skill, prompt-template, and context discovery; and rejects agent web
tools. Provider network remains available to the sandboxed Pi process.

**Verification:** Runtime-policy coverage pins the namespace mounts, auth path,
disposable environment, read-only tool list, host-owned output, and network-tool
rejection. A live bubblewrap probe used the stored OpenRouter credential and
received `OK` from `deepseek/deepseek-v4-pro:xhigh`.
