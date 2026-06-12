---
date: 2026-06-11
slug: https-origin-normalization
pages: [commands/web, gaps]
---

Dogfood incident: a task reached `5-open-pr` with work committed, but the
push failed three times (`git@github.com: Permission denied (publickey)`) and
the daemon quarantined the task — the web row kept saying "Ready to open PR"
with no visible error. Root cause: `gh repo clone` honored the operator's
`git_protocol: ssh`, producing an ssh origin the headless daemon can't
authenticate (SSH auth lived in the 1Password agent; the container has no
keys at all).

Fixes: hivebox registration now rewrites github ssh origins to https
(`ReposController#normalize_origin!`, regression-tested), and the Docker
image configures `gh auth git-credential` as git's https credential helper
for github.com. The quarantine-invisibility problem is recorded as an open
gap in [[gaps]].
