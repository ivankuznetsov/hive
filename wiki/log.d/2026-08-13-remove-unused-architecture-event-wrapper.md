# Remove unused architecture event wrapper

- Removed `EventPublisher#architecture_patrol_finalized`, an unused convenience
  wrapper around the architecture patrol event's prepare-and-publish protocol.
- Kept coverage on the production `prepare_architecture_patrol_finalized` and
  `publish_prepared` path, including capture validation and the targeted hook
  payload.
