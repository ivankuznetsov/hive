require "test_helper"
require "fileutils"
require "rbconfig"
require "hive/agent_skills/canonical_skill"
require_relative "../../packaging/live_agent_skills/workflow_creator_live_setup"

# Thin, authenticated adapter over the packaging-owned U15 setup and runner.
# Offline behavior belongs in their focused unit tests; this test proves only
# the exact installed candidate/OpenClaw closure against a real provider.
class LiveHiveWorkflowCreatorSmokeTest < Minitest::Test
  include HiveTestHelper

  Setup = HiveLiveAgentProof::WorkflowCreatorLiveSetup
  Runner = HiveLiveAgentProof::WorkflowCreatorLiveRunner
  Bundle = HiveLiveAgentProof::WorkflowCreatorBundle
  RUNNER_KEYS = %i[
    candidate_sha model configuration_record execution_options
    external_actions_observer workspace_preparer runtime_install_verifier
  ].freeze
  ENDPOINTS = {
    "openai" => "https://api.openai.com/v1",
    "openrouter" => "https://openrouter.ai/api/v1"
  }.freeze

  def test_exact_openclaw_creator_closure_produces_a_retained_bundle
    skip "set HIVE_LIVE_AGENT_SKILLS=1 to run the authenticated Workflow Creator proof" unless
      ENV["HIVE_LIVE_AGENT_SKILLS"] == "1"

    candidate_sha = HiveLiveAgentProof.validate_sha!(required_env("HIVE_CANDIDATE_SHA"), "candidate_sha")
    evidence_path = File.expand_path(required_env("HIVE_CREATOR_EVIDENCE_PATH"))
    expected_name = HiveLiveAgentProof::WorkflowCreator::Vocabulary.fetch("bundle_files").first
    raise "unexpected Workflow Creator evidence path" unless File.basename(evidence_path) == expected_name

    bundle = File.dirname(evidence_path)
    FileUtils.mkdir_p(bundle, mode: 0o700)
    File.chmod(0o700, bundle)
    Runner.initialize_evidence!(bundle_directory: bundle, candidate_sha:)

    model = required_env("HIVE_LIVE_MODEL")
    provider = model.split("/", 2).first
    raise "unsupported HIVE_LIVE_MODEL provider" unless ENDPOINTS.key?(provider)
    output_root = required_directory("HIVE_CREATOR_SETUP_ROOT")
    workspace = File.join(output_root, "workspace")
    raise "Workflow Creator workspace must be absent before setup" if File.exist?(workspace) || File.symlink?(workspace)

    setup = prepare_setup(
      candidate_sha:, model:, provider:, bundle:, output_root:, workspace:
    )
    result = Runner.run!(**setup.slice(*RUNNER_KEYS), host_environment: ENV)

    assert_equal "passed", result.status, failure_summary(result)
    assert_equal provider, result.provider
    retained = Bundle.retained(
      directory: bundle, expected_primary: result.receipt.value,
      manifest: setup.dig(:execution_options, :manifest), candidate_sha:
    )
    assert_equal "passed", retained.primary.fetch("result")
    assert_equal HiveLiveAgentProof::WorkflowCreator::Vocabulary.fetch("bundle_files").sort,
                 retained.bytes.keys.sort
    refute File.exist?(workspace), "U14 must remove its proof workspace after finalization"
  end

  private

  def prepare_setup(candidate_sha:, model:, provider:, bundle:, output_root:, workspace:)
    Setup.prepare!(
      candidate_dir: required_directory("HIVE_PROOF_ARTIFACTS"), candidate_sha:,
      hive_version: Hive::VERSION, canonical: Hive::AgentSkills::CanonicalSkill.new,
      candidate_runtime_root: File.join(output_root, "candidate-runtime"),
      candidate_hive: required_file("HIVE_PROVEN_HIVE_BIN"), ruby: RbConfig.ruby,
      openclaw_runtime_root: File.join(output_root, "openclaw-runtime"),
      openclaw_entrypoint: required_file("HIVE_OPENCLAW_ENTRYPOINT"),
      node: required_file("HIVE_NODE_BIN"),
      openclaw_lock: required_file("HIVE_OPENCLAW_LOCK"),
      openclaw_package: required_file("HIVE_OPENCLAW_PACKAGE"),
      output_root:, workspace_path: workspace, bundle_directory: bundle,
      model:, provider:,
      transport: {
        "endpoint" => ENDPOINTS.fetch(provider), "proxy" => nil,
        "ca" => nil, "redirects" => "deny"
      },
      correlation_id: correlation_id(candidate_sha), supervisor_options: {}
    )
  rescue StandardError => error
    Runner.fail!(
      bundle_directory: bundle, candidate_sha:, phase: "setup", reason: "setup_failed",
      detail: error.message, exact_secrets: provider_secrets
    )
    raise
  end

  def required_env(name)
    value = ENV[name].to_s
    raise "#{name} is required" if value.empty?
    value
  end

  def required_directory(name)
    path = File.expand_path(required_env(name))
    raise "#{name} is not a directory" unless File.directory?(path) && !File.symlink?(path)
    path
  end

  def required_file(name)
    path = File.expand_path(required_env(name))
    raise "#{name} is not a regular file" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def correlation_id(candidate_sha)
    run = ENV.fetch("GITHUB_RUN_ID", "local")
    attempt = ENV.fetch("GITHUB_RUN_ATTEMPT", "1")
    "workflow-creator:#{candidate_sha}:#{run}:#{attempt}"
  end

  def provider_secrets
    %w[OPENAI_API_KEY OPENROUTER_API_KEY].filter_map do |name|
      value = ENV[name].to_s
      value unless value.empty?
    end
  end

  def failure_summary(result)
    row = result.receipt.respond_to?(:value) ? result.receipt.value : result.receipt
    "Workflow Creator live proof was #{result.status}: #{row['reason']}"
  end
end
