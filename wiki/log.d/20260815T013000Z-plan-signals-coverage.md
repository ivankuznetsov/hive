## 2026-08-15 — Plan signal degradation coverage

`PlanSignals.analyze` degrades rather than raises on unusable input, and every
degradation path now has a test:

- A plan path that does not exist yields `plan_missing`; one that exists but
  cannot be read yields `plan_unreadable`.
- A non-numeric `max_files` yields `invalid_policy_limits` instead of an
  `ArgumentError` escaping the analyzer.
- Frontmatter that is unterminated, parses to something other than a mapping,
  or is unparsable YAML all yield `malformed_frontmatter` while still
  producing a usable result.
- A declared file or a `protected_paths` glob that traverses outside the task
  is dropped, recording `invalid_declared_path` and
  `invalid_protected_path_glob` respectively.
- A literal credential in the plan body prepends the
  `auth_secrets_permissions` mandatory reason with
  `literal_credential_pattern` evidence, and does so alongside — not instead
  of — the categories inferred from declared paths.

The credential case needs a plan that also trips another mandatory category:
the guard's `reasons.none?` block only runs when some reason was already
found, so a plan whose only signal is the credential leaves that branch cold.

See [[modules/plan_review]] and [[testing]].
