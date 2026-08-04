require "test_helper"
require "base64"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "rubygems/package"
require "zlib"
require "hive/agent_skills/canonical_skill"
require_relative "../../../packaging/live_agent_skills/proof"
require_relative "../../../packaging/live_agent_skills/workflow_creator_live_setup"

class WorkflowCreatorLiveSetupTest < Minitest::Test
  include HiveTestHelper

  Setup = HiveLiveAgentProof::WorkflowCreatorLiveSetup
  Runtime = HiveLiveAgentProof::WorkflowCreatorOpenClawRuntime
  SHA = "a" * 40
  NODE_VERSION = "22.23.1"
  OPENCLAW_VERSION = "2026.8.4-test.1"

  def test_builds_bounded_exact_closures_and_prepares_an_isolated_workspace
    with_setup_fixture do |fixture|
      result = prepare(fixture)
      options = result.fetch(:execution_options)
      candidate = options.fetch(:candidate)
      openclaw = options.fetch(:openclaw)
      configuration = JSON.parse(File.binread(result.fetch(:configuration_record)))

      assert_operator candidate.fetch("inventory").length, :<=, 512
      assert_operator openclaw.fetch("inventory").length, :<=, 512
      gateway_relative = candidate.fetch("audit_gateway").delete_prefix("#{candidate.fetch("root")}/")
      assert_includes candidate.fetch("inventory"), gateway_relative
      assert File.directory?(File.dirname(candidate.fetch("audit_gateway")))
      refute File.exist?(candidate.fetch("audit_gateway"))
      assert_equal result.fetch(:skill_source),
                   File.join(candidate.fetch("root"), configuration.dig("skill", "path"))
      assert_equal Digest::SHA256.file(
        File.join(result.fetch(:skill_source), "projection-manifest.json")
      ).hexdigest, configuration.dig("skill", "projection_manifest_sha256")
      assert options.fetch(:archives).values.all? { |row| row.fetch("available_bytes").positive? }
      assert options.fetch(:archives).values.all? { |row| row.fetch("available_entries").positive? }

      observation = prepare_workspace(result, fixture)
      assert_equal "prepared", observation.fetch("status")
      assert_match(/\A[0-9a-f]{64}\z/, observation.fetch("openclaw_effective_policy_sha256"))
      assert File.file?(File.join(fixture.fetch(:workspace), ".hive-openclaw/state/openclaw.sqlite"))
      assert File.file?(File.join(fixture.fetch(:workspace), "skills/hive/SKILL.md"))
      assert File.file?(File.join(fixture.fetch(:workspace), ".hive-state/config.yml"))
      remotes, status = Open3.capture2(fixture.fetch(:git), "-C", fixture.fetch(:workspace), "remote")
      assert status.success?
      assert_empty remotes
    end
  end

  def test_runtime_and_candidate_artifact_tamper_fail_closed
    with_setup_fixture do |fixture|
      result = prepare(fixture)
      executable = result.dig(:execution_options, :candidate, "executable")
      environment = result.dig(:execution_options, :candidate, "environment")
      assert_equal fixture.fetch(:candidate_runtime), environment.fetch("GEM_HOME")
      assert_equal fixture.fetch(:candidate_runtime), environment.fetch("GEM_PATH")
      assert_equal %w[1 1 1], environment.values_at(
        "HIVE_SKIP_LLM_WIKI_SCHEDULER", "HIVE_SKIP_LLM_WIKI_SYSTEMCTL",
        "HIVE_SKIP_LLM_WIKI_POST_COMMIT"
      )
      _stdout, stderr, status = Open3.capture3(environment, executable, "version", unsetenv_others: true)
      assert status.success?, stderr

      File.open(fixture.fetch(:candidate_hive), "ab") { |file| file.write("# drift\n") }
      _stdout, _stderr, status = Open3.capture3(environment, executable, "version", unsetenv_others: true)
      refute status.success?

      File.open(fixture.fetch(:openclaw_entrypoint), "ab") { |file| file.write("// drift\n") }
      assert_raises(Runtime::Error) do
        result.fetch(:runtime_install_verifier).call(
          runtime_install: JSON.parse(File.binread(result.fetch(:configuration_record))).fetch("runtime_install"),
          launcher_sha256: Digest::SHA256.file(result.dig(:execution_options, :openclaw, "executable")).hexdigest
        )
      end
    end

    with_setup_fixture do |fixture|
      File.open(fixture.fetch(:candidate_gem), "ab") { |file| file.write("drift") }
      assert_raises(Setup::Error) { prepare(fixture) }
    end
  end

  def test_first_stage_fixture_is_deterministic_and_observer_is_fail_closed
    first = second = nil
    with_setup_fixture do |fixture|
      result = prepare(fixture)
      fixture_path = result.dig(:execution_options, :candidate, "environment", "HIVE_CLAUDE_BIN")
      first = File.binread(fixture_path)
      prepare_workspace(result, fixture)

      assert_raises(Setup::Error) do
        result.fetch(:external_actions_observer).call(
          workspace: fixture.fetch(:workspace),
          candidate_environment: result.dig(:execution_options, :candidate, "environment")
        )
      end

      research = File.join(
        fixture.fetch(:workspace), ".hive-state/stages/1-research/editorial-live-proof/research.md"
      )
      FileUtils.mkdir_p(File.dirname(research), mode: 0o700)
      File.binwrite(research, "<!-- WAITING -->\n")
      _stdout, stderr, status = Open3.capture3(
        result.dig(:execution_options, :candidate, "environment"), fixture_path,
        chdir: fixture.fetch(:workspace), unsetenv_others: true
      )
      assert status.success?, stderr
      assert_equal({ "status" => "observed", "actions" => [] },
                   result.fetch(:external_actions_observer).call(
                     workspace: fixture.fetch(:workspace),
                     candidate_environment: result.dig(:execution_options, :candidate, "environment")
                   ))

      system(fixture.fetch(:git), "-C", fixture.fetch(:workspace), "remote", "add", "origin",
             "https://example.invalid/hive.git", exception: true)
      assert_raises(Setup::Error) do
        result.fetch(:external_actions_observer).call(
          workspace: fixture.fetch(:workspace),
          candidate_environment: result.dig(:execution_options, :candidate, "environment")
        )
      end
    end

    with_setup_fixture do |fixture|
      result = prepare(fixture)
      second = File.binread(result.dig(:execution_options, :candidate, "environment", "HIVE_CLAUDE_BIN"))
    end
    assert_equal first, second
  end

  def test_candidate_runtime_manifest_is_bounded_but_not_limited_to_small_value_snapshots
    with_setup_fixture do |fixture|
      library = File.join(fixture.fetch(:candidate_runtime), "large-fixture")
      FileUtils.mkdir_p(library, mode: 0o700)
      1_700.times { |index| File.binwrite(File.join(library, format("%04d.rb", index)), "# fixture\n") }

      result = prepare(fixture)
      root = result.dig(:execution_options, :candidate, "root")
      manifest = JSON.parse(File.binread(File.join(root, "runtime/candidate-runtime-manifest.json")))
      assert_equal 1_701, manifest.fetch("files").length
      assert_equal "bin/hive", manifest.fetch("entrypoint")
    end
  end

  private

  def prepare(fixture)
    Setup.prepare!(
      candidate_dir: fixture.fetch(:candidate_dir), candidate_sha: SHA,
      hive_version: Hive::VERSION, canonical: fixture.fetch(:canonical),
      candidate_runtime_root: fixture.fetch(:candidate_runtime),
      candidate_hive: fixture.fetch(:candidate_hive), ruby: RbConfig.ruby,
      openclaw_runtime_root: fixture.fetch(:openclaw_runtime),
      openclaw_entrypoint: fixture.fetch(:openclaw_entrypoint), node: fixture.fetch(:node),
      openclaw_lock: fixture.fetch(:openclaw_lock), openclaw_package: fixture.fetch(:openclaw_package),
      output_root: fixture.fetch(:output), workspace_path: fixture.fetch(:workspace),
      bundle_directory: fixture.fetch(:bundle), model: "openrouter/openai/gpt-5.6-terra",
      provider: "openrouter",
      transport: {
        "endpoint" => "https://openrouter.ai/api/v1", "proxy" => nil,
        "ca" => nil, "redirects" => "deny"
      },
      correlation_id: "workflow-creator-live-setup", supervisor_options: {}
    )
  end

  def prepare_workspace(result, fixture)
    workspace = fixture.fetch(:workspace)
    state = File.join(workspace, ".hive-openclaw")
    home = File.join(state, "home")
    bin = File.join(state, "bin")
    FileUtils.mkdir_p([ workspace, state, home, bin ], mode: 0o700)
    gateway = File.join(bin, "hive")
    File.symlink(result.dig(:execution_options, :candidate, "executable"), gateway)
    config = File.join(state, "openclaw.json")
    File.binwrite(config, JSON.generate(
      "agents" => { "defaults" => { "workspace" => workspace } },
      "tools" => {
        "allow" => %w[read write edit apply_patch exec],
        "fs" => { "workspaceOnly" => true },
        "exec" => { "mode" => "allowlist", "host" => "gateway" }
      }
    ))
    openclaw_environment = {
      "HOME" => home, "OPENCLAW_STATE_DIR" => state, "OPENCLAW_CONFIG_PATH" => config,
      "PATH" => "/usr/bin:/bin", "SHELL" => "/bin/bash", "HIVE_LIVE_PROOF" => "1",
      "OPENROUTER_API_KEY" => "must-not-reach-local-cli"
    }
    result.fetch(:workspace_preparer).call(
      workspace:, candidate_environment: result.dig(:execution_options, :candidate, "environment"),
      openclaw_environment:, gateway_path: gateway
    )
  end

  def with_setup_fixture
    with_tmp_dir do |root|
      canonical = Hive::AgentSkills::CanonicalSkill.new
      artifacts_root = File.join(root, "artifact-input")
      candidate_dir = File.join(root, "candidate-artifacts")
      output = File.join(root, "setup")
      candidate_runtime = File.join(output, "candidate-runtime")
      openclaw_runtime = File.join(output, "openclaw-runtime")
      bundle = File.join(root, "bundle")
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p([ artifacts_root, candidate_runtime, openclaw_runtime, bundle ], mode: 0o700)
      FileUtils.chmod(0o700, bundle)

      candidate_gem = File.join(artifacts_root, "hive-cli-#{Hive::VERSION}.gem")
      source = File.join(artifacts_root, "source.tar.gz")
      File.binwrite(candidate_gem, "candidate-gem\n")
      File.binwrite(source, "candidate-source\n")
      HiveLiveAgentProof::Builder.new(
        candidate_sha: SHA, gem_path: candidate_gem, source_archive: source,
        output_dir: candidate_dir, canonical:
      ).call
      candidate_gem = File.join(candidate_dir, File.basename(candidate_gem))

      candidate_hive = File.join(candidate_runtime, "bin/hive")
      FileUtils.mkdir_p(File.dirname(candidate_hive), mode: 0o700)
      File.binwrite(candidate_hive, fake_hive_source)
      File.chmod(0o700, candidate_hive)

      openclaw_entrypoint = File.join(openclaw_runtime, "node_modules/openclaw/openclaw.mjs")
      FileUtils.mkdir_p(File.dirname(openclaw_entrypoint), mode: 0o700)
      File.binwrite(openclaw_entrypoint, "console.log('openclaw fixture')\n")
      node = File.join(root, "node")
      File.binwrite(node, fake_node_source)
      File.chmod(0o700, node)
      openclaw_package = File.join(root, "openclaw.tgz")
      write_tgz(openclaw_package)
      openclaw_lock = File.join(root, "package-lock.json")
      File.binwrite(openclaw_lock, JSON.generate(package_lock(openclaw_package)))
      git = %w[/usr/bin/git /bin/git].find { |path| File.executable?(path) }

      yield root:, canonical:, candidate_dir:, candidate_gem:, output:, candidate_runtime:,
            candidate_hive:, openclaw_runtime:, openclaw_entrypoint:, node:, openclaw_package:,
            openclaw_lock:, bundle:, workspace:, git:
    end
  end

  def fake_hive_source
    <<~'RUBY'
      require "fileutils"
      require "json"
      if ARGV.first == "init"
        workspace = File.expand_path(ARGV.fetch(1))
        state = File.join(workspace, ".hive-state")
        FileUtils.mkdir_p(state)
        File.write(File.join(state, "config.yml"), "---\ndaemon:\n  enabled: false\n")
        puts JSON.generate(
          "schema" => "hive-init", "ok" => true, "minimal" => true,
          "answers" => {
            "daemon_enabled" => false, "babysitter_enabled" => false,
            "daemon_autostart" => false, "refactor_patrol_enabled" => false,
            "adhoc_auto_fix" => false, "patrol_mode" => "off"
          }
        )
      elsif ARGV == ["version"]
        puts "fixture-hive"
      else
        abort "unexpected fixture argv: #{ARGV.inspect}"
      end
    RUBY
  end

  def fake_node_source
    <<~SH
      #!/bin/sh
      set -eu
      if [ "\${1:-}" = "--version" ]; then
        printf 'v#{NODE_VERSION}\\n'
        exit 0
      fi
      [ -z "\${OPENROUTER_API_KEY:-}" ] || exit 80
      shift
      if [ "\${1:-} \${2:-}" = "config validate" ]; then
        [ -f "$OPENCLAW_CONFIG_PATH" ]
        printf 'Configuration valid\\n'
      elif [ "\${1:-} \${2:-}" = "approvals set" ]; then
        [ "\${3:-}" = "--file" ]
        mkdir -p "$OPENCLAW_STATE_DIR/state"
        hive_approvals=$(cat "$4")
        printf '%s' "\${hive_approvals%?}" > "$OPENCLAW_STATE_DIR/effective-approvals.json"
        printf ',"socket":{"path":"%s/exec-approvals.sock","token":"fixture_socket_token_1234"}}' \
          "$OPENCLAW_STATE_DIR" >> "$OPENCLAW_STATE_DIR/effective-approvals.json"
        : > "$OPENCLAW_STATE_DIR/state/openclaw.sqlite"
        printf 'Writing local approvals.\\n' >&2
        printf '{}\\n'
      elif [ "\${1:-} \${2:-} \${3:-}" = "approvals get --json" ]; then
        printf '{"exists":true,"file":'
        cat "$OPENCLAW_STATE_DIR/effective-approvals.json"
        printf '}\\n'
      else
        exit 81
      fi
    SH
  end

  def write_tgz(path)
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        bytes = "openclaw package\n"
        tar.add_file_simple("package/openclaw.mjs", 0o644, bytes.bytesize) { |io| io.write(bytes) }
      end
    end
  end

  def package_lock(package)
    integrity = "sha512-#{Base64.strict_encode64(Digest::SHA512.file(package).digest)}"
    {
      "name" => "hive-openclaw-proof", "lockfileVersion" => 3,
      "packages" => {
        "" => {
          "dependencies" => { "openclaw" => OPENCLAW_VERSION },
          "engines" => { "node" => NODE_VERSION }
        },
        "node_modules/openclaw" => {
          "version" => OPENCLAW_VERSION,
          "resolved" => "https://registry.npmjs.org/openclaw/-/openclaw-#{OPENCLAW_VERSION}.tgz",
          "integrity" => integrity, "hasInstallScript" => true,
          "engines" => { "node" => ">=22.22.3 <23" }
        }
      }
    }
  end
end
