# 2026-11-28 — Complete GitHub transport error normalization and diagnostics

- Replaced the enumerated socket error list in `Hive::Web::GithubAuth::NETWORK_ERRORS`
  (`lib/hive/web/github_auth.rb`, aliased by `GithubApi::NETWORK_ERRORS`) with
  the shared transport superclass family (`Net::OpenTimeout`, `Net::ReadTimeout`,
  `Net::WriteTimeout`, `Timeout::Error`, `SocketError`, `OpenSSL::SSL::SSLError`,
  `SystemCallError`, `IOError`), plus shared `TRANSPORT_ERROR_MESSAGE`,
  `transport_reason`, and `warn_transport`.
- Required an explicit `logger:` on `Hive::Web::GithubAuth.new`, wired
  `GithubTransportLogger.build` (`web/app/models/github_transport_logger.rb`)
  into `SessionsController`, `ApplicationController`, and `GithubApi`'s default
  logger so warnings emit one untagged four-field JSON line (`event`, literal
  `operation`, safe `reason`, `error_class`) without altering request-tagged
  logging, and passed a null logger in `Hive::CommandMaintenanceAuthority.github`
  while preserving reloadable owner revocation checks.
- Scoped `GithubApi` (`web/app/models/github_api.rb`) transport handling to a
  nested `execute_transport` boundary with a private `TotalDeadlineExceeded`
  timer class:
  - Transport-raised Net::HTTP open/read/write timeouts and bare transport
    `Timeout::Error` were reclassified from `deadline_exceeded` to
    `network_failed` with the shared connection guidance and `cause: nil`.
  - Only expiry of `GithubApi`'s own outer total timer produces
    `reason: "deadline_exceeded"`, the existing deadline message, and a
    `total_deadline` warning with `GithubApi::TotalDeadlineExceeded` and
    `cause: nil`.
  - HTTP policy, JSON parsing, GraphQL/response validation, and post-transport
    programming or `SystemCallError` failures stay outside transport
    normalization and emit no transport warning.
- Updated `web/app/views/tasks/_publication.html.erb` to render the shared
  connection guidance when a cached diagnostic has
  `source == "publication_cache"` and `reason == "network_failed"`, keeping
  humanized labels for all other reasons.
- Verified with focused gem tests (`test/unit/web/github_auth_test.rb`,
  `test/unit/command_maintenance_authority_test.rb`,
  `test/unit/command_receipt_contract_test.rb`,
  `test/unit/command_receipt_maintenance_test.rb`), all 32 changed-selected gem
  tests, focused Rails tests (`web/test/models/github_api_test.rb`,
  `web/test/integration/sessions_flow_test.rb`,
  `web/test/integration/tasks_test.rb`, `web/test/integration/repos_test.rb`),
  `bundle exec rake coverage:changed` (100% exact line coverage on both changed
  gem files), `bundle exec rake test:agent_cli_runtime`, and serial
  `bundle exec rake test:hive` fallback.
- See [[commands/web]].
