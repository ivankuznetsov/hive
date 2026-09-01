## Fix guardrail pins diff prefixes

- `FixGuardrail.capture_diff` now forces `a/` and `b/` path prefixes.
- Repository-local `diff.noprefix=true` can no longer hide protected-file edits, additions, or deletions from file-path detectors.
- Added a real-git regression test that proves the captured diff and the guardrail result remain protected under that configuration.
