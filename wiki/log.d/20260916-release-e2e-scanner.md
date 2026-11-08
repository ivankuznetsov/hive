# Supply the release E2E scanner

Release E2E ran source-checkout publication scenarios without preparing Betterleaks, unlike ordinary CI. An isolated missing-scanner run reproduced the pipeline failure while the same profile passed with the scanner present. Add the existing pinned/checksummed bundle step before release scenarios, and retain reports on all outcomes. No runtime scan bypass or candidate byte substitution is introduced.
