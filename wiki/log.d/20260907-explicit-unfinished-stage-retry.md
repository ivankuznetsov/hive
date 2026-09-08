# Explicit retry of unfinished stages

Digest image recovery exposed an old zero-exit receipt replaying forever even
after its workflow parser was fixed: the task still said WAITING, but `hive
run` returned the expired successful process receipt without executing.
New explicit run requests now reach plain unfinished stage runners. Exact
request replays, automatic dispatch replay, completed outputs, coding
brainstorm, and controller workflows retain their established behavior.

Regression coverage exercises WAITING/EXECUTE_WAITING/REVIEW_WAITING/ERROR,
exact-request and automatic replay, completed outputs, and Patrol exclusion.
