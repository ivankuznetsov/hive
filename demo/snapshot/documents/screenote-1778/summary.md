# Summary for replace-screenote-cli-api-key-260708-545b

## Summary
The Screenote CLI now authenticates with OAuth bearer tokens instead of project-scoped API keys, while the REST v1 API keeps accepting API keys for existing callers. CI and agents can authenticate deterministically with a pre-provisioned token (`--token`, `SCREENOTE_TOKEN`, or config `token`) that never triggers a prompt or a browser. Developers can run `screenote login` for an interactive OAuth flow, and `screenote logout` to clear stored credentials.

Because the Go CLI branch was never merged, CLI-facing API-key auth is removed cleanly — there is no `--api-key`, `SCREENOTE_API_KEY`, or config `api_key`, and no hidden fallback. Server-side API-key support for REST and MCP is untouched.

## PR
https://github.com/ivankuznetsov/screenote/pull/37

## Commits
```
fb56348 docs(wiki): post-commit refresh for replace-screenote-cli-api-key-260708-545b@ed167b1
b676b11 test(api): assert OAuth project list roles match each membership
48ca1c4 fix(screenote): give default HTTP client a timeout and close upload pipe
7305ca4 fix(cli): harden login lifecycle and stored-credential guards
ed167b1 chore(6-review): commit residual worktree changes
8163771 docs(wiki): post-commit refresh for replace-screenote-cli-api-key-260708-545b@256fede
39222fc docs(cli): add --project to README screenshot list example
7c67e67 test(api): lock bearer auth precedence and OAuth write/scoping edges
256fede fix(api): preload project screenshot counts and guard nil api-key project
9617c4a fix(cli): harden OAuth login flow and local project resolution
7d6ccd9 docs(cli): U7 document OAuth-first CLI authentication
e7ffca8 feat(api): U5-U6 accept OAuth bearer tokens for REST v1
2ab00a5 feat(cli): U4 add OAuth login and stored refresh
41028ac feat(cli): U1-U3 adopt OAuth bearer token contract
7b0dda6 chore: merge draft Go CLI for OAuth auth work
a75dab1 docs(wiki): post-commit refresh for add-a-go-cli-for-260708-edec@951cd5e
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
