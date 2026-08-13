# Remove unused nonblocking managed lock

- Removed `ManagedDirectory#try_with_lock`, which had no production caller.
- Retained descriptor-bound blocking `with_lock` behavior and its path,
  binding, permissions, and caller-error coverage used by managed stores.
