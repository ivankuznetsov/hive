# Empty artifact-producer output enters bounded repair

**Action:** Moved the producer role launch and final-message parsing inside the
existing bounded descriptor-repair boundary. An empty or malformed final
message now starts the one fresh repair context with `previous_output: null`,
while controller-issued captures and the Pi runtime remain available. Agent,
custody, and other store failures raised before a producer result exists still
fail closed instead of being mislabeled as descriptor repair.

**Why:** Live Pi dogfooding captured the required Screener video and explicit
post-Approve flash screenshot, then the provider ended with an empty assistant
message. `run_role!` raised before the old rescue boundary, so Hive discarded
valid captures, consumed the evidence attempt, and parked at the recapture cap
without ever issuing the repair turn.

**Tests:** The artifacts unit suite now reproduces the empty producer response,
requires a second prompt containing the bounded error and null prior output,
and proves the controller-owned WebM remains present for admission.
