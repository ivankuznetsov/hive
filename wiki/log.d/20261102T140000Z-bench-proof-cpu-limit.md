# Fit the real Docker credential proof to hosted runners

The Ubuntu CI daemon rejected the eight-CPU request inherited from the fake
Docker fixture because it exposes only four CPUs. Override `HB_CPUS` to one
for the real Docker credential matrix. Keep resource-forwarding fixture
expectations and production resource defaults unchanged.

Local validation: a temporary Docker shim rejected requests above four CPUs
and forwarded all other calls to the real daemon. The original proof failed
with exit 125; after the override, `test:bench_isolation_proof` passed with
3 runs/45 assertions and the expected Linux Bash 3.2 skip. Its nested matrix
passed all 15 tests/602 assertions. Hosted confirmation remains pending.
