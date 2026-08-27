# TaskResolver numeric ids parse strictly as base 10

**Problem:** A zero-padded numeric TARGET silently resolved to the wrong task.
`TaskResolver.new("010").resolve` selected the folder whose `meta.yml` id is 8
(bare `Kernel#Integer` reads the leading `0` as an octal prefix), and
`TaskResolver.new("09").resolve` raised a raw `ArgumentError: invalid value
for Integer()` instead of any Hive error type.

**Cause:** `TaskResolver#resolve_numeric_id` passed the digit string straight
to `Integer(@target)` with no explicit base, even though the
`/\A\d+\z/` guard already proved the target is all decimal digits.

**Fix:** `lib/hive/task_resolver.rb` now calls `Integer(@target, 10)`, so
`"010"` resolves to id 10 and `"09"` to id 9 by decimal value. Regression
tests in `test/unit/task_resolver_test.rb` cover both a zero-padded id above
the octal range (with an id-8 decoy present) and one below it.

See [[task_resolver]].
