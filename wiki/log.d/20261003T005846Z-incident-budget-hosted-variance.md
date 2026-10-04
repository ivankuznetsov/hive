# Restore incident aggregate timing headroom

The advisory incident-duration job measured a 32.641-second total for three
individually healthy real-subprocess incidents, beyond the 32-second aggregate
threshold. Another recent hosted run reached 34.015 seconds without an
individual incident exceeding its ceiling.

The aggregate advisory budget is now below 36 seconds while retaining the
below-16-second per-incident signal and all functional and report-integrity
gates. Regression coverage includes the observed hosted variance and continues
to reject an aggregate of exactly 36 seconds.
