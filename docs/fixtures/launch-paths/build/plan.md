# Build plan

> **Deterministic replay fixture.** No production repository was changed by
> this example.

1. Add a minimal `Gemfile`, `config.ru`, and Rack-compatible application.
2. Serve `/healthz` and serialize only `status`, `version`, and `revision`.
3. Add direct unit coverage for a known revision, the `unknown` fallback, and
   an unrelated path.
4. Run `bundle exec ruby -Itest test/health_app_test.rb` and inspect the diff.

Acceptance response:

```json
{"status":"ok","version":"0.1.0","revision":"7c9e12a"}
```
