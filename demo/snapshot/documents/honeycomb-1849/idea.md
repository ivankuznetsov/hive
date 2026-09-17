---
slug: security-lint-ci-for-package-260709-dcee
created_at: 2026-07-09T11:19:54Z
original_text: |
  Security lint CI for package submissions. Fork-safe, label-gated GitHub Actions (pattern: hive-bench validate-submission.yml — pull_request not pull_request_target, contents:read, maintainer applies safe-to-validate). Checks on the PR's packages/**: run the package validator; SECRET/PII scan (port hive-bench validator/secret_scan.rb pattern set); instruction static analysis — extract and post as a PR comment every shell command found in instruction files, every permission the descriptor requests, and deny-pattern hits (curl|bash pipes, credential paths ~/.ssh ~/.aws .credentials, base64 exfil shapes, network calls to non-allowlisted hosts). A workflow is UNLISTABLE until the lint passes AND a human review approves — the lint surfaces evidence for the reviewer, it does not replace them (instructions are prompts; injection can be semantic, not just syntactic).
---

# security-lint-ci-for-package-260709-dcee

Security lint CI for package submissions. Fork-safe, label-gated GitHub Actions (pattern: hive-bench validate-submission.yml — pull_request not pull_request_target, contents:read, maintainer applies safe-to-validate). Checks on the PR's packages/**: run the package validator; SECRET/PII scan (port hive-bench validator/secret_scan.rb pattern set); instruction static analysis — extract and post as a PR comment every shell command found in instruction files, every permission the descriptor requests, and deny-pattern hits (curl|bash pipes, credential paths ~/.ssh ~/.aws .credentials, base64 exfil shapes, network calls to non-allowlisted hosts). A workflow is UNLISTABLE until the lint passes AND a human review approves — the lint surfaces evidence for the reviewer, it does not replace them (instructions are prompts; injection can be semantic, not just syntactic).

<!-- WAITING -->

NAMING (2026-07-09): a published workflow package is called a HONEYCOMB.
Use the term in all user-facing surfaces: manifest field docs, CLI output,
CI comments, README/catalog. The public catalog page is hive.sh/honeycombs.
