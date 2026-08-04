require "test_helper"
require "digest"
require "json"
require "open3"
require_relative "../../../packaging/live_agent_skills/workflow_creator_live_runner"

class WorkflowCreatorLiveRunnerTest < Minitest::Test
  include HiveTestHelper

  Creator = HiveLiveAgentProof::WorkflowCreator
  Runner = HiveLiveAgentProof::WorkflowCreatorLiveRunner
  SHA = "a" * 40
  OPENAI_SECRET = "openai-selected-secret"
  OPENROUTER_SECRET = "openrouter-selected-secret"
  TEST_OPENCLAW_VERSION = "2026.8.4-test.1"
  TEST_OPENCLAW_INTEGRITY = "sha512-#{[ "test-openclaw-integrity" ].pack("m0")}"
  TEST_NODE_ENGINE = ">=22.19<23"
  TEST_NODE_VERSION = "22.23.1"
  NPM_REGISTRY = "https://registry.npmjs.org"

  FakeResult = Data.define(:status)

  class FakeSession
    attr_reader :closed, :finished, :launches

    def initialize(options)
      @options = options
      @workspace_path = options.fetch(:workspace_path)
      FileUtils.mkdir_p(@workspace_path, mode: 0o700)
      @gateway_path = File.join(File.dirname(@workspace_path), "workflow-creator-gateway")
      File.binwrite(@gateway_path, "#!/bin/sh\nexit 0\n")
      File.chmod(0o700, @gateway_path)
      @launches = []
    end

    attr_reader :gateway_path, :workspace_path

    def run_outer_workflow_creator(**launch)
      @launches << launch
      { "exit_code" => 0 }
    end

    def run_outer_authorized_work(**launch)
      @launches << launch
      Creator::Vocabulary.fetch("files").each do |relative|
        path = File.join(@workspace_path, relative)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        content = if relative.end_with?("editorial.yml")
          <<~YAML
            id: editorial
            stages:
              - name: research
                kind: agent
                state_file: research.md
                instruction: editorial/research.md
                permissions: yolo
              - name: draft
                kind: agent
                state_file: draft.md
                instruction: editorial/draft.md
                permissions: yolo
              - name: approval
                kind: human
                state_file: approval.md
                input: draft.md
                outcomes:
                  approve:
                    complete: true
                    artifact: draft.md
                  reject:
                    to: draft
          YAML
        else
          "authored:#{relative}\n"
        end
        File.binwrite(path, content)
      end
      task = File.join(@workspace_path, ".hive-state", "stages", "1-research", "created-editorial-42")
      FileUtils.mkdir_p(task, mode: 0o700)
      File.binwrite(
        File.join(task, "meta.yml"),
        YAML.dump(
          "slug" => "created-editorial-42", "workflow" => "editorial",
          "idempotency_key" => Creator::Vocabulary.fetch("task_key")
        )
      )
      { "exit_code" => 0 }
    end

    def draft!(executed_instruction:)
      @instruction = executed_instruction
      receipt = {
        "installed_manifests" => [
          bundle_record("candidate_installation", "candidate-installed-manifest.json", "candidate"),
          bundle_record("openclaw_installation", "openclaw-installed-manifest.json", "openclaw")
        ],
        "task_slug_binding" => { "value" => "created-editorial-42" }
      }
      bytes = Creator::Values.capture(receipt).canonical_bytes
      HiveLiveAgentProof::WorkflowCreatorExecution::Draft.new(
        receipt_bytes: bytes, receipt_sha256: Digest::SHA256.hexdigest(bytes), receipt_size: bytes.bytesize
      )
    end

    def finish!(primary_row:)
      @primary = primary_row
      @finished = true
      FakeResult.new(status: "passed")
    end

    def close
      @closed = true
    end

    private

    def bundle_record(kind, path, seed)
      { "kind" => kind, "path" => path, "sha256" => Digest::SHA256.hexdigest(seed), "size" => seed.bytesize }
    end
  end

  class EarlyTaskSession < FakeSession
    def run_outer_workflow_creator(**launch)
      super
      FileUtils.mkdir_p(
        File.join(@workspace_path, ".hive-state", "stages", "1-research", "too-early"),
        mode: 0o700
      )
    end
  end

  class InvalidGraphSession < FakeSession
    def run_outer_authorized_work(**launch)
      super
      descriptor = File.join(@workspace_path, Creator::Vocabulary.fetch("files").first)
      File.binwrite(descriptor, "id: editorial\nstages: []\n")
    end
  end

  def test_selects_each_provider_with_both_credentials_and_strips_authority
    %w[openai openrouter].each do |provider|
      with_fixture(provider:) do |fixture|
        result = run_fixture(fixture)
        session = fixture.fetch(:sessions).fetch(0)
        child = session.launches.fetch(0).fetch(:environment)
        selected = provider == "openai" ? "OPENAI_API_KEY" : "OPENROUTER_API_KEY"
        opposite = provider == "openai" ? "OPENROUTER_API_KEY" : "OPENAI_API_KEY"

        assert_equal "passed", result.status, result.receipt.value.inspect
        assert_equal provider, result.provider
        assert_equal fixture.dig(:environment, selected), child.fetch(selected)
        refute child.key?(opposite)
        %w[GH_TOKEN GITHUB_TOKEN GIT_CONFIG_GLOBAL GIT_ASKPASS SSH_AUTH_SOCK SSH_ASKPASS].each do |name|
          refute child.key?(name), "#{name} escaped into the OpenClaw child"
        end
        config = JSON.parse(File.binread(child.fetch("OPENCLAW_CONFIG_PATH")))
        assert_equal "allowlist", config.dig("tools", "exec", "mode")
        assert_equal [ File.dirname(File.join(session.workspace_path, ".hive-openclaw", "bin", "hive")) ],
                     config.dig("tools", "exec", "pathPrepend")
        refute_includes JSON.generate(config), "passEnv"
        assert_equal fixture.fetch(:shell_path), child.fetch("SHELL")
        refute File.exist?(File.join(session.workspace_path, ".hive-openclaw", "exec-approvals.json"))
      end
    end
  end

  def test_workspace_preparer_runs_after_gateway_configuration_and_before_model_loops
    with_fixture do |fixture|
      prepared = false
      preparer = lambda do |workspace:, candidate_environment:, openclaw_environment:, gateway_path:|
        session = fixture.fetch(:sessions).fetch(0)
        assert_empty session.launches
        assert_equal session.workspace_path, workspace
        assert_equal fixture.dig(:execution_options, :candidate, "environment"), candidate_environment
        assert File.file?(openclaw_environment.fetch("OPENCLAW_CONFIG_PATH"))
        assert File.symlink?(gateway_path)
        assert_equal File.realpath(session.gateway_path), File.realpath(gateway_path)
        prepared = true
        workspace_preparation(fixture)
      end

      result = run_fixture(fixture, workspace_preparer: preparer)

      assert_equal "passed", result.status, result.receipt.value.inspect
      assert prepared
    end
  end

  def test_trusted_shell_strips_provider_and_repository_authority_from_real_command_environment
    with_fixture do |fixture|
      hostile = fixture.fetch(:environment).merge(
        "NODE_OPTIONS" => "--require=/tmp/ignored.js",
        "OPENCLAW_GATEWAY_TOKEN" => "openclaw-token",
        "custom_api_key" => "lowercase-secret"
      )
      stdout, stderr, status = Open3.capture3(
        hostile, fixture.fetch(:shell_path), "-c", "/usr/bin/env", unsetenv_others: true
      )

      assert status.success?, stderr
      %w[OPENAI_API_KEY OPENROUTER_API_KEY GH_TOKEN GITHUB_TOKEN GIT_CONFIG_GLOBAL GIT_ASKPASS
         SSH_AUTH_SOCK SSH_ASKPASS NODE_OPTIONS OPENCLAW_GATEWAY_TOKEN custom_api_key].each do |name|
        refute_match(/^#{Regexp.escape(name)}=/, stdout, "#{name} escaped into a model command")
      end
    end
  end

  def test_missing_or_unsupported_provider_and_missing_selected_credential_are_typed
    cases = [
      [ "", {}, "missing_model", "failed" ],
      [ "anthropic/claude", {}, "unsupported_provider", "failed" ],
      [ "openrouter/openai/gpt-5.6-terra", { "OPENROUTER_API_KEY" => "" },
        "missing_provider_credential", "blocked" ]
    ]
    cases.each do |model, overrides, reason, status|
      provider = model.start_with?("openai/") ? "openai" : "openrouter"
      with_fixture(provider:, model:) do |fixture|
        fixture.fetch(:environment).merge!(overrides)
        result = run_fixture(fixture)
        receipt = retained_receipt(fixture)

        assert_equal status, result.status
        assert_equal reason, receipt.fetch("reason")
        assert_empty fixture.fetch(:sessions)
      end
    end
  end

  def test_hostile_transport_overrides_fail_before_credential_bearing_execution
    with_fixture do |fixture|
      fixture.fetch(:environment)["HTTPS_PROXY"] = "https://attacker.invalid:443"

      result = run_fixture(fixture)

      assert_equal "failed", result.status
      assert_equal "transport_override", retained_receipt(fixture).fetch("reason")
      assert_empty fixture.fetch(:sessions)
    end

    with_fixture do |fixture|
      record = JSON.parse(File.binread(fixture.fetch(:configuration_record)))
      record.fetch("transport")["endpoint"] = "https://attacker.invalid/v1"
      write_canonical(fixture.fetch(:configuration_record), record)

      result = run_fixture(fixture)

      assert_equal "failed", result.status
      assert_equal "invalid_transport_identity", retained_receipt(fixture).fetch("reason")
    end
  end

  def test_invalid_dependency_closure_and_binary_fail_before_execution
    with_fixture do |fixture|
      File.open(fixture.fetch(:lock_path), "ab") { |file| file.write("\n") }

      result = run_fixture(fixture)

      assert_equal "failed", result.status
      assert_equal "invalid_openclaw_closure", retained_receipt(fixture).fetch("reason")
      assert_empty fixture.fetch(:sessions)
    end

    with_fixture do |fixture|
      File.chmod(0o600, fixture.fetch(:openclaw_binary))

      result = run_fixture(fixture)

      assert_equal "failed", result.status
      assert_equal "invalid_openclaw_binary", retained_receipt(fixture).fetch("reason")
      assert_empty fixture.fetch(:sessions)
    end


    with_fixture do |fixture|
      File.open(fixture.fetch(:shell_path), "ab") { |file| file.write("# drift\n") }

      result = run_fixture(fixture)

      assert_equal "failed", result.status
      assert_equal "invalid_tool_environment", retained_receipt(fixture).fetch("reason")
      assert_empty fixture.fetch(:sessions)
    end

    with_fixture do |fixture|
      candidate = fixture.dig(:execution_options, :candidate)
      skill_manifest = File.join(candidate.fetch("root"), candidate.fetch("inventory").fetch(0))
      File.open(skill_manifest, "ab") { |file| file.write("drift\n") }

      result = run_fixture(fixture)

      assert_equal "failed", result.status
      assert_equal "invalid_skill_projection", retained_receipt(fixture).fetch("reason")
      assert_empty fixture.fetch(:sessions)
    end
  end


  def test_runtime_install_requires_packaging_owned_verification
    with_fixture do |fixture|
      result = run_fixture(fixture, runtime_install_verifier: nil)

      assert_equal "blocked", result.status
      assert_equal "runtime_install_unverified", retained_receipt(fixture).fetch("reason")
      assert_empty fixture.fetch(:sessions)
    end
  end

  def test_runtime_install_drift_after_model_execution_fails_the_claim
    with_fixture do |fixture|
      scans = 0
      verifier = lambda do |runtime_install:, launcher_sha256:|
        scans += 1
        assert_equal fixture.fetch(:runtime_install).fetch("launcher_sha256"), launcher_sha256
        next runtime_install if scans == 1

        runtime_install.merge("tree_sha256" => Digest::SHA256.hexdigest("changed-runtime"))
      end

      result = run_fixture(fixture, runtime_install_verifier: verifier)

      assert_equal "failed", result.status
      assert_equal "runtime_install_changed", retained_receipt(fixture).fetch("reason")
      assert_equal 2, scans
    end
  end

  def test_external_actions_are_observed_after_both_model_loops_and_fail_closed
    with_fixture do |fixture|
      observed = false
      observer = lambda do |workspace:, candidate_environment:|
        session = fixture.fetch(:sessions).fetch(0)
        assert_equal 2, session.launches.length
        assert_equal session.workspace_path, workspace
        assert_equal fixture.dig(:execution_options, :candidate, "environment"), candidate_environment
        observed = true
        { "status" => "observed", "actions" => [] }
      end

      result = run_fixture(fixture, external_actions_observer: observer)

      assert_equal "passed", result.status, result.receipt.value.inspect
      assert observed
    end

    with_fixture do |fixture|
      result = run_fixture(
        fixture,
        external_actions_observer: ->(**) { { "status" => "assumed", "actions" => [] } }
      )

      assert_equal "failed", result.status
      assert_equal "external_actions_unverified", retained_receipt(fixture).fetch("reason")
    end
  end

  def test_workspace_claims_require_creation_only_and_exact_authored_graph_evidence
    with_fixture do |fixture|
      factory = lambda do |**options|
        EarlyTaskSession.new(options).tap { |session| fixture.fetch(:sessions) << session }
      end

      result = run_fixture(fixture, execution_factory: factory)

      assert_equal "failed", result.status
      assert_equal "creation_only_task_created", retained_receipt(fixture).fetch("reason")
    end

    with_fixture do |fixture|
      factory = lambda do |**options|
        InvalidGraphSession.new(options).tap { |session| fixture.fetch(:sessions) << session }
      end

      result = run_fixture(fixture, execution_factory: factory)

      assert_equal "failed", result.status
      assert_equal "authored_graph_invalid", retained_receipt(fixture).fetch("reason")
    end
  end

  def test_initial_receipt_precedes_preflight_and_success_is_finalized_and_closed
    with_fixture do |fixture|
      factory = lambda do |**options|
        initial = retained_receipt(fixture)
        assert_equal [ "preflight", "not_started", "failed" ],
                     initial.values_at("phase", "reason", "result")
        session = FakeSession.new(options)
        fixture.fetch(:sessions) << session
        session
      end

      result = run_fixture(fixture, execution_factory: factory)
      session = fixture.fetch(:sessions).fetch(0)
      retained = retained_receipt(fixture)

      assert_equal "passed", result.status, result.receipt.value.inspect
      assert_equal "passed", retained.fetch("result")
      assert session.finished
      assert session.closed
      refute_includes File.binread(fixture.fetch(:primary_path)), OPENAI_SECRET
      refute_includes File.binread(fixture.fetch(:primary_path)), OPENROUTER_SECRET
    end
  end

  def test_execution_failure_replaces_initial_receipt_with_secret_free_typed_failure
    with_fixture do |fixture|
      factory = lambda do |**_options|
        raise HiveLiveAgentProof::WorkflowCreatorExecution::Error,
              "provider rejected #{OPENROUTER_SECRET}"
      end

      result = run_fixture(fixture, execution_factory: factory)
      receipt = retained_receipt(fixture)

      assert_equal "failed", result.status
      assert_equal "execution_failed", receipt.fetch("reason")
      assert_includes receipt.fetch("detail"), "[REDACTED]"
      refute_includes File.binread(fixture.fetch(:primary_path)), OPENROUTER_SECRET
    end
  end

  def test_initialize_and_fail_entrypoints_preserve_typed_uploadable_evidence
    with_tmp_dir do |root|
      bundle = File.join(root, "bundle")
      FileUtils.mkdir_p(bundle, mode: 0o700)
      FileUtils.chmod(0o700, bundle)
      environment = {
        "HIVE_CANDIDATE_SHA" => SHA,
        "HIVE_CREATOR_EVIDENCE_PATH" => File.join(bundle, "openclaw-workflow-creator.json")
      }

      assert_equal 0, Runner::Command.call([ "initialize" ], environment:)
      assert_equal 0, Runner::Command.call([ "fail", "setup", "artifact_download_failed" ], environment:)
      receipt = JSON.parse(File.binread(environment.fetch("HIVE_CREATOR_EVIDENCE_PATH")))

      assert_equal [ "setup", "artifact_download_failed", "failed" ],
                   receipt.values_at("phase", "reason", "result")
    end
  end

  private

  def run_fixture(fixture, execution_factory: nil, runtime_install_verifier: :fixture,
                  external_actions_observer: nil, workspace_preparer: nil)
    execution_factory ||= lambda do |**options|
      FakeSession.new(options).tap { |session| fixture.fetch(:sessions) << session }
    end
    runtime_install_verifier = lambda do |runtime_install:, launcher_sha256:|
      assert_equal fixture.fetch(:runtime_install), runtime_install
      assert_equal fixture.fetch(:runtime_install).fetch("launcher_sha256"), launcher_sha256
      runtime_install
    end if runtime_install_verifier == :fixture
    external_actions_observer ||= ->(**) { { "status" => "observed", "actions" => [] } }
    workspace_preparer ||= ->(**) { workspace_preparation(fixture) }
    Runner.run!(
      candidate_sha: SHA, model: fixture.fetch(:model), host_environment: fixture.fetch(:environment),
      configuration_record: fixture.fetch(:configuration_record),
      execution_options: fixture.fetch(:execution_options), external_actions_observer:,
      workspace_preparer:, execution_factory:, runtime_install_verifier:
    )
  end

  def with_fixture(provider: "openrouter", model: nil)
    with_tmp_dir do |root|
      bundle = File.join(root, "bundle")
      openclaw_root = File.join(root, "openclaw")
      candidate_root = File.join(root, "candidate")
      skill_root = File.join(candidate_root, "skill", "hive")
      workspace = File.join(root, "workspace")
      runtime_install_root = File.join(root, "openclaw-runtime-install")
      FileUtils.mkdir_p(
        [ bundle, runtime_install_root, skill_root, File.join(openclaw_root, "bin"), File.join(openclaw_root, "runtime"),
          File.join(openclaw_root, "security") ], mode: 0o700
      )
      FileUtils.chmod(0o700, bundle)
      skill_manifest = File.join(skill_root, "projection-manifest.json")
      File.binwrite(skill_manifest, "{\"schema\":\"test-openclaw-skill\"}\n")
      skill_sha = Digest::SHA256.file(skill_manifest).hexdigest
      binary = File.join(openclaw_root, "bin", "openclaw")
      File.binwrite(binary, "#!/bin/sh\nexit 0\n")
      File.chmod(0o700, binary)
      shell_path = File.join(openclaw_root, "security", "hive-creator-shell")
      File.binwrite(shell_path, Runner.shell_sanitizer_bytes)
      File.chmod(0o700, shell_path)
      node = File.join(openclaw_root, "runtime", "node")
      File.binwrite(node, "#!/bin/sh\nprintf 'v#{TEST_NODE_VERSION}\\n'\n")
      File.chmod(0o700, node)
      lock_path = File.join(openclaw_root, "package-lock.json")
      lock = package_lock
      File.binwrite(lock_path, JSON.generate(lock))
      package = File.join(openclaw_root, "openclaw.tgz")
      File.binwrite(package, "openclaw-package\n")
      model ||= provider == "openai" ? "openai/gpt-5.6-terra" : "openrouter/openai/gpt-5.6-terra"
      runtime_install = {
        "schema" => "hive-openclaw-runtime-install/v1", "schema_version" => 1,
        "root" => runtime_install_root, "tree_sha256" => Digest::SHA256.hexdigest("runtime-tree"),
        "file_count" => 34_911, "directory_count" => 2_040, "total_size" => 123_456_789,
        "launcher_sha256" => Digest::SHA256.file(binary).hexdigest
      }
      config_path = File.join(openclaw_root, "creator-configuration.json")
      record = configuration_record(
        provider:, model:, lock_path:, shell_path:, openclaw_root:, runtime_install:,
        candidate_root:, skill_sha:
      )
      write_canonical(config_path, record)
      inventory = [ binary, node, lock_path, package, shell_path, config_path ].map do |path|
        path.delete_prefix("#{openclaw_root}/")
      end.sort
      environment = {
        "PATH" => "/usr/bin:/bin", "LANG" => "C.UTF-8", "OPENAI_API_KEY" => OPENAI_SECRET,
        "OPENROUTER_API_KEY" => OPENROUTER_SECRET, "GH_TOKEN" => "github-secret",
        "GITHUB_TOKEN" => "github-secret-2", "GIT_CONFIG_GLOBAL" => "/tmp/host.gitconfig",
        "GIT_ASKPASS" => "/tmp/askpass", "SSH_AUTH_SOCK" => "/tmp/ssh-agent",
        "SSH_ASKPASS" => "/tmp/ssh-askpass"
      }
      hive_version = "1.0.0"
      manifest_files = [ "hive-agent-skills-#{SHA}.tar.gz", "hive-cli-#{hive_version}.gem",
                         "hive-source-#{SHA}.tar.gz" ].to_h do |name|
        [ name, { "sha256" => Digest::SHA256.hexdigest(name), "size" => name.bytesize } ]
      end
      manifest = {
        "schema" => "hive-live-agent-candidate-artifacts", "schema_version" => 1,
        "candidate_sha" => SHA, "hive_version" => hive_version, "skill_version" => "2026.8.4",
        "canonical_digest" => Digest::SHA256.hexdigest("canonical"), "files" => manifest_files
      }
      execution_options = {
        candidate_sha: SHA, manifest:,
        candidate: {
          "root" => candidate_root, "environment" => {},
          "inventory" => [ skill_manifest.delete_prefix("#{candidate_root}/") ]
        },
        openclaw: {
          "root" => openclaw_root, "version" => TEST_OPENCLAW_VERSION, "inventory" => inventory,
          "executable" => binary, "interpreter_or_launcher" => node, "lock" => lock_path, "package" => package
        },
        archives: {}, workspace_path: workspace, bundle_directory: bundle,
        correlation_id: "live-creator", supervisor_options: {}
      }
      yield root:, bundle:, model:, environment:, configuration_record: config_path, lock_path:,
            openclaw_binary: binary, shell_path:, runtime_install:, sessions: [], execution_options:,
            primary_path: File.join(bundle, "openclaw-workflow-creator.json")
    end
  end

  def package_lock
    {
      "name" => "hive-openclaw-creator-proof", "lockfileVersion" => 3,
      "packages" => {
        "" => { "dependencies" => { "openclaw" => TEST_OPENCLAW_VERSION },
                "engines" => { "node" => TEST_NODE_VERSION } },
        "node_modules/openclaw" => {
          "version" => TEST_OPENCLAW_VERSION,
          "resolved" => "https://registry.npmjs.org/openclaw/-/openclaw-#{TEST_OPENCLAW_VERSION}.tgz",
          "integrity" => TEST_OPENCLAW_INTEGRITY, "hasInstallScript" => true,
          "engines" => { "node" => TEST_NODE_ENGINE }
        }
      }
    }
  end

  def configuration_record(provider:, model:, lock_path:, shell_path:, openclaw_root:, runtime_install:,
                           candidate_root:, skill_sha:)
    {
      "schema" => Runner::CONFIGURATION_SCHEMA, "schema_version" => 1,
      "candidate_sha" => SHA, "provider" => provider, "model" => model,
      "transport" => {
        "endpoint" => Runner::PROVIDERS.fetch(provider).fetch("endpoint"),
        "proxy" => nil, "ca" => nil, "redirects" => "deny"
      },
      "dependency" => {
        "package" => "openclaw", "version" => TEST_OPENCLAW_VERSION,
        "registry" => NPM_REGISTRY, "integrity" => TEST_OPENCLAW_INTEGRITY,
        "lock_sha256" => Digest::SHA256.file(lock_path).hexdigest,
        "package_count" => 2, "node_engine" => TEST_NODE_ENGINE, "node_version" => TEST_NODE_VERSION,
        "lifecycle_scripts" => [ "node_modules/openclaw" ]
      },
      "tool_environment" => {
        "pass_env" => [], "authority" => "shell_sanitized",
        "shell" => {
          "path" => shell_path.delete_prefix("#{openclaw_root}/"),
          "sha256" => Digest::SHA256.file(shell_path).hexdigest, "size" => File.size(shell_path)
        }
      },
      "runtime_install" => runtime_install,
      "skill" => {
        "path" => "skill/hive", "projection_manifest_sha256" => skill_sha
      }
    }
  end

  def workspace_preparation(fixture)
    digest = fixture.fetch(:configuration_record).then { |path| Digest::SHA256.file(path).hexdigest }
    {
      "schema" => "hive-workflow-creator-workspace-preparation", "schema_version" => 1,
      "status" => "prepared", "skill_manifest_sha256" =>
        JSON.parse(File.binread(fixture.fetch(:configuration_record))).dig("skill", "projection_manifest_sha256"),
      "init_stdout_sha256" => digest, "git_head" => "b" * 40,
      "openclaw_config_validation_sha256" => digest,
      "openclaw_effective_policy_sha256" => digest
    }
  end

  def write_canonical(path, value)
    File.binwrite(path, Creator::Values.capture(value).canonical_bytes)
    File.chmod(0o600, path)
  end

  def retained_receipt(fixture)
    JSON.parse(File.binread(fixture.fetch(:primary_path)))
  end
end
