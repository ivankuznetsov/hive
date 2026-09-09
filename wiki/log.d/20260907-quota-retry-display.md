## Preserve actual scheduler decisions for quota failures

Operational snapshots no longer replace the scheduler's retry assessment with
a provider reset estimate. Hourly cooldown, retry time, safety, and ownership
remain visible even before a recovery request is admitted. Provider reset
estimates remain informational data; they do not establish a scheduling hold.
The regression test checks a reset estimate later than the actual retry time.
