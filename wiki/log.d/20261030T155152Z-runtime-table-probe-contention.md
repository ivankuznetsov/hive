# Runtime table probes preserve contention

Replaced Sequel's error-swallowing `table_exists?` calls with a shared SQLite
catalog query. Startup schema validation, quiescence snapshots and copying,
dispatch admission/context handling, receipt-pin cleanup, and worker context
restoration now propagate busy errors instead of treating tables as absent.

Boundary regressions inject a one-shot wrapped SQLite busy error at the actual
probe SQL and require the typed busy outcome from startup and quiescence reads.
A separate real exclusive-lock test verifies that the catalog query propagates
contention and succeeds after release. Historical lock attribution remains
unverified; see [[gaps]] and [[commands/status]].
