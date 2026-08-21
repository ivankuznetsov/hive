# Lock-contention events keep the holder that blew the deadline

`BrainstormAnswerWriter.append!` retries the per-task lock until a deadline,
then emits `:answer_lock_contention` so operators can grep the bot log for
whatever was holding the lock. The holder captured from the rescued
`Hive::ConcurrentRunError` was assigned *after* the deadline check, so the
holder observed on the deadline-crossing pass was discarded — on a loaded
machine a single `try_append` can outlast the whole budget, breaking on the
first pass and emitting `holder: nil` in exactly the case the event exists to
explain.

The holder is now captured before the break. Coverage adds a timing-free case
that pins a zero deadline to the first pass; the pre-existing 0.1s-deadline
test only reached this path when the clock cooperated, which made it flake
under CI load.
