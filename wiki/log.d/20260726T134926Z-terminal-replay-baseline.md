## Stop unchanged terminal attempts from replaying every daemon tick

- When durable dispatch reports that the exact task generation already has a
  successful terminal attempt, the daemon now records the observed state-file
  mtime as the persisted dispatch baseline.
- An unchanged waiting marker is therefore admitted only once after discovery
  or upgrade instead of querying and logging the same terminal receipt every
  tick.
- A later operator or agent edit still has a newer mtime and remains eligible
  for normal dispatch.
