# Pin the babysitter push lease to the captured remote SHA

The PR-fix shell recipe stops on command failures and supplies the original
remote SHA in its force-with-lease argument. Remote changes after the final
comparison remain protected even when a background fetch refreshes tracking
refs. A real-repository regression verifies the rejected push preserves the
advanced remote branch.
