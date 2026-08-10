## [2026-07-26T10:40:00Z] web — serve isolated assets during demo capture

**Action:** Enabled Propshaft's server middleware when
`HIVE_WEB_ASSETS_DIR` selects the private capture asset directory. Capture
already compiled into that external directory to keep linked source worktrees
clean, but production Rails otherwise returned 404 for the generated asset
URLs and recorded a technically valid, unstyled page. The opt-in is confined to
the credential-free capture runtime; normal production web serving is
unchanged.

**Tests:** Added a production-Rails subprocess regression that resolves the
digested application stylesheet and requests it through the real middleware,
asserting a non-empty CSS 200 response from the isolated output path.
