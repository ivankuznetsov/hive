# Architecture Patrol preflights review capacity

- The daemon now checks durable Architecture Patrol review-launch capacity before exposing discovery work.
- Exhausted review capacity leaves queued jobs unchanged and avoids child-process churn.
- Classified Architecture Patrol actions remain eligible while discovery is paused.
