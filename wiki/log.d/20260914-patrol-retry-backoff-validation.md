# Patrol retry backoff validation

PR #1327 enforces durable discovery retry deadlines at claim time. Updated the process-death integration test to prove that an early manual retry does not invoke the reviewer and that retrying at the deadline resumes the next feature. The CLI claim rejection now includes retry backoff instead of attributing every rejection to another worker.
