# Summary for add-a-go-cli-for-260708-edec

## Summary
Screenote can now be driven from a shell or CI script without an MCP client. `go install github.com/ivankuznetsov/screenote/cmd/screenote@latest` installs a Cobra-based CLI that talks to the REST API, emits JSON on stdout, and reports machine-readable errors on stderr with stable exit codes. MCP remains the rich agent protocol; the CLI is the scriptable REST counterpart, and both share the same query and serialization behavior.

## PR
https://github.com/ivankuznetsov/screenote/pull/36

## Commits
```
951cd5e chore(8-finalize): commit residual worktree changes
202d1be docs(wiki): post-commit refresh for add-a-go-cli-for-260708-edec@9547ed9
9547ed9 chore(6-review): commit residual worktree changes
6ef76a1 docs(wiki): post-commit refresh for add-a-go-cli-for-260708-edec@77c4287
77c4287 fix(review): apply pass 02 findings
7ba4c4c ci: run Go job on main and adopt goreleaser v2 ids key
40d1844 refactor(screenote): drop dead response types and simplify request body param
c67c427 fix(cli): harden annotation aggregation and usage-error contract
6240105 docs(wiki): post-commit refresh for add-a-go-cli-for-260708-edec@f78823e
f78823e chore(6-review): commit residual worktree changes
f0ee24c docs(wiki): post-commit refresh for add-a-go-cli-for-260708-edec@131265a
a53da10 fix(api): harden REST params and eliminate serializer N+1 queries
131265a fix(cli): correct annotation aggregation, usage exits, and uploads
62e4138 fix(cli): stream screenshot upload bodies
1f2b4e4 chore(release): U6 document and build CLI
c65e071 feat(cli): U3-U4 add Go REST CLI
760c98c feat(api): U1-U2 expand v1 REST contract
```

## Review
Review passes: 2
Triage bias: courageous
