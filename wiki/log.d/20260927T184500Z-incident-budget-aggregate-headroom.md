# Incident budget aggregate headroom

The advisory incident-duration job measured a 30.643-second total for the three
enabled real-subprocess incidents, just beyond the former 30-second aggregate
threshold while every functional scenario passed. Raised only the advisory
aggregate cap to 32 seconds, preserving the strict boundary and the
per-incident 16-second signal while covering ordinary hosted-runner scheduling
variance.

The focused regression reproduces the exact hosted durations, and the boundary
test proves an exactly 32-second aggregate is still rejected.
