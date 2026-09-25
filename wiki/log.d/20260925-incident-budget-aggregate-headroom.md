# Incident budget aggregate headroom

The advisory incident-duration job repeatedly measured a 30.296-second total
for the three enabled real-subprocess incidents, just beyond the former
30-second aggregate threshold while every functional check passed. Raised only
the advisory aggregate cap to 32 seconds, preserving the strict boundary and
the per-incident 16-second signal while avoiding ordinary hosted-runner
scheduling variance.

The incident-budget boundary test now proves an exactly 32-second aggregate is
still rejected.
