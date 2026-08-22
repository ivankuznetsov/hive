# Browser recordings stop independently of model latency

**Action:** The outcome-evidence browser gateway now stops an active recording
after 25 seconds and caches the private stop result until the producer's later
`record stop` call validates and publishes it. Closing the gateway cancels the
controller timer. Stop-time duration probing remains the fail-closed admission
boundary at 30 seconds.

**Why:** Live Pi dogfood with `openrouter/stealth/ox-alpha` showed that a model
could request a shorter take correctly but spend minutes between tool calls,
leaving ffmpeg to capture throughout. Rejecting the overlong file only after the
next model turn bounded publication, not the recording process or retry cost.

**Coverage:** `ArtifactsBrowserGatewayTest` proves a delayed producer reuses one
controller-issued stop and publishes the bounded result without invoking a
second browser stop.
