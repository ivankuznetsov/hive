---
date: 2026-06-19
slug: babysitter-gh-api-preview-host-gate
pages: [modules/babysitter, testing]
---

`bin/hive-babysitter-stub-gh`: `gh api -p <preview> https://host` bypassed the
new endpoint host check. `api_endpoint_host_override?` consumed the long
`--preview` value (it is in `API_ENDPOINT_VALUE_OPTIONS`) but the short `-p`
form was not in the value-taking short list `-H -X -F -f -q -t`. The scanner
treated `-p` as a no-value flag, stopped on the preview name, found it was not a
URL, and returned `false` — never inspecting the trailing external URL, so the
call reached real gh against an agent-chosen host.

Fix: added `p` to the short-option regex (`/\A-[HXFfqtp]/`) and to the
separate-value list (`-H -X -F -f -q -t -p`), matching how the other
value-taking shorts are consumed. The short list now covers every long
value-taking option that has a short equivalent
(`--field/-F`, `--header/-H`, `--jq/-q`, `--method/-X`, `--preview/-p`,
`--raw-field/-f`, `--template/-t`).

Whole-class check: the sibling scanners do not share this defect.
`api_read_only?`'s `else` branch only ever over-blocks when an unconsumed value
happens to match a payload flag (fail-safe), and `target_operands` serves
`repo view` / `pr view`, which have no `-p`. `api_endpoint_host_override?` was
the only under-blocking site.

Regression coverage in `test/unit/babysitter/dry_run_env_test.rb`: separate
short, glued short, and long preview forms in front of `https://evil.example.com`
must skip; the same forms against a default-host endpoint
(`repos/owner/repo`) must still reach real gh.
