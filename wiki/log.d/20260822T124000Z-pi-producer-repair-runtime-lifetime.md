# Pi producer repairs retain their attempt runtime

**Action:** Made the outcome-evidence capture toolkit, rather than the generic
spawn helper, own a managed Pi producer policy until attempt teardown. A fresh
bounded descriptor-repair context can now reuse controller-issued captures and
the live capture mailbox before the runtime home is removed.

**Why:** Live dogfooding produced a valid Screener video but returned one
controller-owned `rendering` field. Hive correctly requested its bounded JSON
repair, then bubblewrap failed because the first spawn had already deleted
`/tmp/hive-managed-pi-evidence-*`. The daemon recovered only by starting a new
evidence attempt and recapturing the product flow.

**Tests:** Pins caller-owned runtime-policy cleanup at the generic spawn seam and
the artifacts producer launch contract, alongside the bounded producer-repair
regression.
