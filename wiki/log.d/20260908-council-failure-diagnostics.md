## Keep council agent failure diagnostics

Council reviewer and revision errors now retain agent status, exit code, and a
separate full log locator. Regression tests cover a timeout without error text
and an exited revision agent with an oversized provider message. This fixes
empty council error summaries; it does not change retry or provider policy.
