# Harden the OpenClaw creator proof trust boundary

- Replaced loose candidate/OpenClaw executable inputs with typed installation
  receipts that bind reviewed artifacts, private install roots, executable
  realpaths, and executable digests.
- Replaced mutable global OpenClaw installation with Node 22.23.1 plus
  `npm ci --ignore-scripts` from a committed 306-package exact-integrity lock.
- Made the gateway the only approved OpenClaw executable, held audit
  serialization through candidate completion, recorded exit/signal/success,
  stripped all provider credentials downstream, and derived zero external
  actions from the retained deny-by-default policy and completed audit.
- Added child-subreaper containment for process-group escapes, bounded archive
  entries/directories/depth/inodes, actual-tree enumeration, recursive evidence
  sanitation, proof-first preflight evidence, and portable Bundler fixtures.
- Verified the child-subreaper flag through `PR_GET_CHILD_SUBREAPER` and made
  the supervisor drain adopted descendants from its top-level exit path, so a
  parent interruption cannot bypass teardown.

**Pages:** [[testing]] [[dependencies]] [[gaps]]
