# Remove unused directory metadata probe

- Removed `ManagedDirectory#directory_metadata`, which had no production
  caller.
- Retained descriptor-stable directory custody, entry-type checks, and
  file-metadata reads used by managed stores.
