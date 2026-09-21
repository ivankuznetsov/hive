# New-idea resolution sweep

Confirmed main still resolved scoped submissions by row position, then integrated
PR #1350 with current main. Removed the unused project object from resolution
results and the test-only name argument to numeric entry. Production callers
consume state and exact name. Added the scrollable-list regression for a cleared
highlight, preserving explicit selection and staged draft recovery.

The focused-test overrides retain current main's coverage machinery and its
loaded-source/uncovered-line checks. The historical mapping-inventory comment
was triaged no-fix and independently found not to demonstrate a current false
success. Later live-registry lookup remains outside the snapshot preflight.
