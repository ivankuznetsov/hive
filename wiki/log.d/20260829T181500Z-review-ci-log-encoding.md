# Review CI log encoding boundary

**Problem:** `Hive::Gh.capture3` intentionally returns binary strings, but failed GitHub Actions logs can contain valid non-ASCII UTF-8 bytes. `failing_jobs_with_logs` forwarded that binary-labelled text into the review CI-fix ERB prompt, where it raised `Encoding::CompatibilityError` before the fixer could run. The same transport fed babysitter prompts.

**Action:** Normalize failing job names, fetched logs, and fetch diagnostics to scrubbed UTF-8 before budget allocation and tail clipping. Normalize every `CiFix.clean_output` input again before ANSI stripping and prompt rendering so injected command runners have the same text contract.

**Evidence:** Added a real CI-fix prompt-boundary regression using binary-labelled UTF-8 plus an invalid byte, and a GitHub transport regression covering normalization through tail clipping. Focused GitHub, remote-CI, CI-fix, and babysitter tests remain green.
