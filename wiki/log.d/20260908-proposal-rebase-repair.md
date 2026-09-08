## Proposal branch rebase repair

Finished the interrupted proposal branch rebase without restoring deleted
projection machinery. Producer rollback now snapshots only the journal and
proposal source files; integration fixtures use the SQLite attempt repository.
