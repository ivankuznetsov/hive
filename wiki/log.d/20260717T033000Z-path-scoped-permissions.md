# 2026-07-17: Path-scoped workflow permissions

- Added portable task-relative `Read(path)` and `Edit(path)` rules to scoped
  workflow permissions.
- Scoped launches now use Claude `dontAsk` and normalize file rules to absolute
  permission paths, allowing project reads with docs-only writes without an
  interactive permission prompt.
- Treat qualified `Edit` as the family rule for every built-in file editor and
  reject unsupported file-tool path rules in favor of Claude's enforced
  `Read(path)` / `Edit(path)` forms.
- Preserved MCP wildcard/hyphenated tool rules, normalized Windows drive paths,
  and moved unresolvable file-rule failures to config load.
- Documented that Claude merges CLI permission rules with loaded setting
  sources, so descriptor scopes express Hive's request but do not erase
  broader trusted operator policy.
