require "digest"
require "fiddle"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "rubygems/package"
require "set"
require "tmpdir"
require "yaml"
require "zlib"
require "hive/agent_skills/canonical_skill"
require_relative "proof"

module HiveLiveAgentProof
  module OpenClawCreatorProof
    EVIDENCE_SCHEMA = "hive-live-workflow-creator-evidence".freeze
    OPENCLAW_VERSION = WORKFLOW_CREATOR_OPENCLAW_VERSION
    OPENCLAW_INTEGRITY = WORKFLOW_CREATOR_OPENCLAW_INTEGRITY
    OPENCLAW_LOCK_PATH =
      File.expand_path("openclaw/package-lock.json", __dir__).freeze
    OPENCLAW_LOCK_SHA256 = WORKFLOW_CREATOR_OPENCLAW_LOCK_SHA256
    OPENCLAW_LOCK_PACKAGE_COUNT = WORKFLOW_CREATOR_OPENCLAW_PACKAGE_COUNT
    DETAIL_LIMIT = 1_000
    CREDENTIAL_LIMIT = 4_096
    PROVIDER_CREDENTIAL_ENV = WORKFLOW_CREATOR_PROVIDER_ENV
    PASSTHROUGH_ENV = %w[
      PATH LANG LC_ALL TERM TMPDIR SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
      HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
    ].freeze

    class Failure < StandardError
      attr_reader :phase, :reason

      def initialize(phase:, reason:, detail:)
        @phase = phase
        @reason = reason
        super(detail)
      end
    end
    require_relative "openclaw_creator_proof/installation_receipt"
    require_relative "openclaw_creator_proof/safe_tar_materializer"
    require_relative "openclaw_creator_proof/audit_gateway"
    require_relative "openclaw_creator_proof/process_runner"
    require_relative "openclaw_creator_proof/openclaw_configuration"
    require_relative "openclaw_creator_proof/project_sandbox"
    require_relative "openclaw_creator_proof/proof_inspector"
    require_relative "openclaw_creator_proof/workspace_installer"
    require_relative "openclaw_creator_proof/evidence_document"
    require_relative "openclaw_creator_proof/environment_policy"
    require_relative "openclaw_creator_proof/proof_executor"
    require_relative "openclaw_creator_proof/runner"
  end
end
