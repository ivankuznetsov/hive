# Build outcome

> **Deterministic replay fixture.** This page is an inspectable walkthrough
> artifact, not a measured full replay.

The memorable result is one safe response:

```json
{"status":"ok","version":"0.1.0","revision":"7c9e12a"}
```

Apply `patch.diff` to an empty Git repository, run `bundle install`, then run
`bundle exec ruby -Itest test/health_app_test.rb`. Compare `review.md` with the
resulting repository diff and real test output. The fixture's next action is a
provider-backed clean replay; do not open a pull request from these synthetic
files.
