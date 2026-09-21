---
title: Confine real-user test access to authenticated smoke tests
type: change
created: 2026-08-31
---

## Test environment safety

`HIVE_TEST_ALLOW_REAL_USER_ENV=1` now fails closed unless every requested test
file is under `test/smoke/`. Valid authenticated smoke processes keep the
operator `HOME` for agent credentials but receive a disposable `HIVE_HOME`, so
Hive runtime paths cannot resolve into the operator installation. Disposable
XDG data/bin roots and removal of inherited `HIVE_PREFIX` also protect the
shell installer's managed QMD tree and user-bin links. Regression coverage
proves both the non-smoke rejection and the complete smoke-only Hive install
path isolation boundary.

The focused `bin/test` loader now hands its leading test-file list to the guard
before requiring those files. This keeps legitimate focused smoke runs working
after `ARGV` consumption without weakening mixed or non-smoke rejection. A
provider-free smoke test verifies the retained operator home and disposable
Hive/install roots through the real focused runner while allowing normal suite
cleanup to complete.

Direct Ruby launches now classify the executed program whenever it is under
`test/`, closing the unit-program plus smoke-`ARGV` bypass. The Rake smoke task
loads its real-user opt-in inside the test child instead of mutating the parent
Rake environment, so task sequences cannot leak that access to later suites.
Documentation distinguishes redirected installer writes from intentional
read/execute discovery of operator tools already on `PATH`.
