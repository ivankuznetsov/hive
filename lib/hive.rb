require "agent_cli_runtime"
require_relative "hive/version"
require_relative "hive/runtime_identity"
require_relative "hive/errors"
# The Schemas namespace (SCHEMA_VERSIONS, envelope helpers, closed enums)
# lives in its own file so schema ownership does not sit in the root
# entrypoint. Requiring it here keeps the public constant path unchanged.
require_relative "hive/schemas"

module Hive
  MIN_CLAUDE_VERSION = "2.1.118".freeze
  # Canonical GitHub org + repo. Referenced by the release probe
  # (UpdateCheck), the brew tap + installer URL (Commands::Update), etc.
  # One place to change on a repository rename.
  REPO_OWNER = "ivankuznetsov".freeze
  REPO_NAME = "hive".freeze
  ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES = 256 * 1024
  ARTIFACT_CAPTURE_MANIFEST_PRODUCER_MAX_BYTES = 240 * 1024
  PROJECT_CAPTURE_PROVIDER_MAX_COMMAND_BYTES = 16 * 1024
  PROJECT_CAPTURE_PROVIDER_MAX_EVIDENCE_BYTES = 64 * 1024

  autoload :DiagnosticEvidence, File.expand_path("hive/diagnostic_evidence.rb", __dir__)
  autoload :DiagnosticHelpers, File.expand_path("hive/diagnostic_helpers.rb", __dir__)
end
