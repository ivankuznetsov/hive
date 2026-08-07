# Keep web recovery receipts stable through daemon tick start

**Change:** The shared web status command now retains the same daemon
generation's still-valid completed scheduler snapshot while the next daemon
tick is in its brief `started` phase.

**Why:** Live dogfood showed the recovery overlay toggling between real
cooldown receipts and `scheduler_observation_unavailable` on every daemon tick.
Each toggle changed the semantic page token and caused two unnecessary Turbo
refresh GETs. Daemon restart, generation drift, expiry, and every non-started
unavailable state continue to invalidate the retained observation.

**Evidence:** Focused status-feed tests pin both same-generation retention and
new-generation refusal.
