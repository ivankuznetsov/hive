# Recover provider-health torn tails atomically

Provider Health now replays complete or partial unterminated final journal
records from the verified prefix without mutating during inspection. The next
accepted mutation compares against the exact torn source bytes and replaces the
tail while appending its event in one atomic write, avoiding failed reset calls
that had already truncated state.
