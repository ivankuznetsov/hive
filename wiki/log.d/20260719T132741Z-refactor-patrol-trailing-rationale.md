# Architecture Patrol accepts a canonical leading JSON fence

**Action:** Updated the read-only Architecture Patrol reviewer to normalize one leading JSON fence even when Claude appends a plain-text leverage rationale. The first fenced document remains the only canonical result: leading prose and any additional fence still fail closed, while the exact provider response remains durable in `final-message.txt` for audit. Added focused regression coverage and updated [[commands/refactor-patrol]] and [[testing]].
