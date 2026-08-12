# Preserve open-circuit and cooldown exclusions

Route evaluation now reports both `circuit_open` and `circuit_cooldown` while
an automatic circuit is open and still before its half-open eligibility time.
All routing-bearing schemas share the complete stable exclusion vocabulary,
with a drift guard against the durable recovery contract.
