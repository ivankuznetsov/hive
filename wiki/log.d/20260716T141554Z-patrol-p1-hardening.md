# Patrol P1 retry, identity, and deadline hardening

Agent version and capability preflights now own a bounded process group, escalate
TERM to KILL, and reap their output readers, so a hung CLI or stdout-inheriting
descendant cannot strand architecture-patrol discovery before the stage timeout.

Architecture discovery now shares one configurable monotonic wall-clock budget
across every mapped feature. Each agent spawn receives only the remaining slice,
and unfinished features stay durable for a later run. Created pull requests must
also prove the exact validated base OID as well as their head and repository
identity before review handoff.

Ordinary optional review handoffs now use the same fingerprint-locked exact
reconciliation as mandatory handoffs. A retry after an ambiguous rename or
directory-fsync failure reuses the matching synthetic review task and rejects
conflicting PR/head metadata instead of creating a duplicate.
