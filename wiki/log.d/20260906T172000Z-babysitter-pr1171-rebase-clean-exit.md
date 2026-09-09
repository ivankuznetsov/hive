## Babysitter rebase — retain CleanExit safety semantics

Rebased the Pi durable-plan checkpoint branch onto current `main`. CleanExit now
returns a staged-mode safety rejection before invoking the blob secret scanner;
unsafe gitlinks and symlinks remain rejected while regular-file scans retain the
same exact-waiver behaviour. Refreshed the runtime-control-plane inventory and
the CleanExit waiver fixture for Betterleaks rule identifiers.

Verification: focused CleanExit, stage-literal, and runtime inventory tests
(40 runs, 368 assertions).
