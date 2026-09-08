## Stop dispatching exhausted candidate verification in a loop

Task 43106 consumed 332 charged dispatches on 2026-09-08 while its review held
only eight provider attempts. Verification quota exhaustion became blocked,
but freshness compared the unchanged original plan against its unpromoted
candidate. Status therefore kept dispatching the same exhausted review.

Transient verification now schedules an hourly recovery series; existing
blocked verification records can enter that path. Freshness uses the original
plan until execution is authorized, then requires the promoted candidate.
Tests reproduce both defects, check multiple hourly retries without repeating
revision, and retain rejection of external plan edits and uncleared execution.
