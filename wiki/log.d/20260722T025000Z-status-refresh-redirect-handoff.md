# Preserve the status refresh guard across redirects

- Kept form submission admission at document scope across Stimulus morph reconnects, and kept the successful redirect destination on the document root across Turbo body replacement.
- Suppressed late background refresh signals only while the browser remains on the submitting URL; refreshes resume after the final redirect URL is active.
- Blocked same-URL Turbo replace visits while a status mutation or redirect handoff is active, so a refresh accepted just before the native submit boundary cannot later win over the mutation redirect.
- Delayed the redirect-handoff system-test refresh injection until after `turbo:submit-end` listeners return, covering the cross-controller race that intermittently pulled Board/Grid switches back to `/` in hosted CI.
