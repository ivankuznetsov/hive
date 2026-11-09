## 2026-11-08 — Review CI gate requires protected checks; rewound review comments post again

- `Review::RemoteCi` now counts the base branch's required status checks. Once
  the exact head is MERGEABLE and its present checks settled, the runner reads
  the required contexts once per base via the new
  `Hive::Gh.required_status_check_contexts` (`gh api
  repos/<repo>/branches/<base>/protection/required_status_checks`) and only
  settles green after every required context reported a green conclusion on
  that head. Missing at `timeout_sec.review_ci` fails closed with
  `REVIEW_ERROR phase=ci gate=github reason=required_checks_missing`. HTTP
  404/403 means no required set (previous behavior); other lookup failures are
  retried within the bound and fail closed as `reason=required_checks_unknown`.
  Failing non-required checks are still CI failures, as before.
- `Review::GithubPublisher` scopes its dedupe header to the review generation:
  generations after a backward-approve archive use
  `### Reviewer: <name> - Pass NN (review generation G)`, where
  `PassArchive.generation` is 1 + archived generation directories. Generation 1
  keeps the bare header, so earlier comments still dedupe; the new pass 01 of a
  rewound review is posted instead of being skipped as already posted.
- Resolves both entries recorded by #1629 in `wiki/gaps.md`; classic
  protection only (rulesets not read) is recorded as the remaining gap.
