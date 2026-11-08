# Register missing-identity admission events

Registered `attempt_identity_deferred` in the daemon logger's closed event enum.
Without registration, deferring an incomplete task correctly at admission still
crashed the daemon when logging the result. Added a regression exercising the
dispatcher admission path with the real logger rather than a permissive fake.
