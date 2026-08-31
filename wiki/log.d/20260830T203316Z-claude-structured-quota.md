# 2026-08-30 — Claude structured quota classification

Agent CLI Runtime now types Claude's message-free rejected `rate_limit_event`
for its known five-hour and seven-day subscription windows as a provider
limit. Reviewers and triage therefore preserve `limits_reached` recovery
instead of flattening exhausted Claude quota to `exit_code=1` or `unknown`.
