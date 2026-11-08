# Reject overlong browser proof while the producer can recover

The managed browser gateway now probes a stopped WebM before publishing it.
Recordings longer than the proof contract's 30-second maximum are rejected at
the tool call, and the stopped logical session is cleared so the evidence
producer can make a shorter replacement without leaving the current attempt.

The capture receipt exposes the same limit. Previously an agent could complete
an otherwise valid and expensive artifacts run before final admission reported
`proof video exceeds 30 seconds`, forcing a whole daemon retry.
