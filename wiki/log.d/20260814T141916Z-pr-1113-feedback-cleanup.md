# PR 1113 feedback cleanup: retry pacing and scoped filters

- Config migration publishes atomically with the original file mode and a
  directory sync. Flow-style legacy Patrol keys normalize only their affected
  top-level section, preserving unrelated config bytes and comments.
- The 12-feature safety slice now belongs only to durable PR/job-manifest
  discovery. Each slice checkpoints before the next child resumes it, while an
  on-demand scan processes its complete supplied scope.
- Architecture discovery now keeps ordinary partial/error retry at 60 seconds
  while structured `token_limit` and `turn_limit` envelopes share the fixed
  one-hour runaway cooldown already used by action retries.
- `hive refactor-patrol --changed-since` is documented as a filter that must be
  paired with `--feature`, `--entrypoint`, or `--path`; it no longer claims to
  boost a standalone full discovery.
- Ordinary Patrol documentation now describes fixed feature/fix/PR work slices,
  wall-clock bounds, the project-wide agent lock, and the single per-agent fuse
  without deleted cycle/day launch headroom or quota-exhaustion behavior.
- TUI boundary and hyperlink tests now pin their intended stdout TTY state, so
  running the test suite from an interactive terminal cannot enter the live TUI
  loop or change plain-output assertions.
- An on-demand review that exhausts the thesis cap now reports partial scope
  and retains its prior scan watermark instead of claiming the omitted tail.
- A standalone retired-policy config rewrite requests its daemon restart before
  later project-specific migration work can fail. The YAML surgery also keeps
  following comments with the surviving key or section they document.
- Hive Web's bounded newest-first job snapshot is now an explicitly internal
  projection; only CLI list/show responses claim the public jobs-v2 schema.
