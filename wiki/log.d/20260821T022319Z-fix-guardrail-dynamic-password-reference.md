# Review fix guardrail ignores dynamic password references

The post-fix secret guardrail no longer treats obvious runtime password
lookups such as `password: params[:password]` or
`password: ENV.fetch("DATABASE_PASSWORD")` as committed secret literals.
Literal password assignments still stop the review loop. The shared
`Hive::SecretPatterns` scanner remains conservative for redaction consumers;
the exception is applied only while classifying added source-code lines in the
fix guardrail.

This prevents a successful autonomous fix pass from parking for operator
approval merely because a controller forwards user-supplied password input.

## Changed

- `lib/hive/stages/review/fix_guardrail.rb`
- `test/unit/stages/review/fix_guardrail_test.rb`
- `wiki/modules/secret_patterns.md`
