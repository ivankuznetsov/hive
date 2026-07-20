# Prevent live refreshes from aborting idea submissions

- Reproduced the hivebox composer failure as a real Turbo race: the
  filesystem-driven status refresh could stop the originating form request
  after `Commands::New` created the task but before the permanent composer saw
  a successful response, leaving a duplicate-ready draft and staged image.
- The composer now suppresses only page-wide refresh stream actions while its
  POST is in flight. Targeted project replacements on the submitting page and
  all live refreshes on other clients continue normally.
- The pipeline browser test injects the competing refresh at submit-start and
  verifies the successful flash, cleared text/chip/upload transport, retained
  project selection, persisted asset, live external update, and approval path.
- The Grok first-login integration scenario now fixes its authentication state
  explicitly, so a developer's real local subscription credentials cannot turn
  the expected `Start login` CTA into `Log in again` and fail the suite.
