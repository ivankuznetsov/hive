# Remove unused dispatch queued predicate

- Removed `Bot::DispatchRequestWriter::DispatchReference#queued?`, which had no
  production caller.
- Kept durable deferral and resolution-race coverage on the reference's
  canonical `status == :queued` value.
