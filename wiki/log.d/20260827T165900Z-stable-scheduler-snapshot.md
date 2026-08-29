# Preserve completed scheduler authority through later ticks

**Change:** After one successful daemon reconciliation, tick start and tick
failure no longer replace the same generation's still-valid completed
scheduler snapshot. The next successful tick replaces it atomically. Before
the first success, `started` and `failed` remain explicit.

**Why:** One malformed or failed scan previously made every operational client
lose scheduler ownership even though a recent coherent task graph, capacity
frame, queue projection, and recovery overlay were still valid. Web carried a
process-local workaround; the producer now owns the rule for CLI, Web, TUI,
bot, and watch consumers alike.

**Safety:** Retention never changes `observed_at`, tick sequence, daemon
generation, source window, or task bindings. The original deadline still
expires, and a shorter reloaded poll interval can only clamp that deadline.
