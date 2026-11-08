# SQLite retries after the final bounded wait

The shared status contention budget now allows SQLite to retry after its final
positive wait, then refuses further waiting on the next busy callback. This
preserves recovery for locks released throughout the one-second allowance.
A deterministic real SQLite lock regression releases at 995ms during the final
slice and verifies successful reading with no extra waiting. Exhaustion,
shared-connection waiting, and sub-resolution termination remain covered.
