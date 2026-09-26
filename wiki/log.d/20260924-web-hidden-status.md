# Pause status updates in hidden Web tabs

Hive Web releases a hidden tab's status subscription and reconnects when the
tab becomes visible. When every subscriber has left, recurring scans stop;
its next subscriber receives the retained snapshot while an immediate
background refresh catches up. Other visible tabs keep their normal updates.
An already-started refresh is allowed to finish, and returning tabs share it
instead of cancelling and restarting the same work.

The browser reuses existing owner cleanup, fences late consumer setup, removes
visibility listeners on DOM teardown, and clears the prior catch-up latch when
hiding. Feed and browser regressions cover idle scan counts, immediate resume,
two-tab updates, interrupted visits during a refresh, and hidden or detached sources.

See [Web command](../commands/web.md) and the installed-service measurement gap
in [known gaps](../gaps.md).
