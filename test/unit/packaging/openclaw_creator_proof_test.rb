require "test_helper"
require "base64"
require "json"
require "rbconfig"
require "rubygems/package"
require "timeout"
require "zlib"
require_relative "../../../packaging/live_agent_skills/openclaw_creator_proof"
require_relative "../../../packaging/live_agent_skills/openclaw_creator_proof/gateway_runtime/attempt_ledger"
require_relative "../../../packaging/live_agent_skills/workflow_creator_evidence_driver"

class OpenClawCreatorProofTest < Minitest::Test
  include HiveTestHelper

  SHA = "a" * 40
  CREDENTIAL = "proof-credential-with-enough-entropy".freeze

  def test_preflight_failure_still_writes_typed_schema_v1_evidence
    with_tmp_dir do |dir|
      evidence_path = File.join(dir, "evidence.json")
      runner = build_runner(
        candidate_sha: "not-a-sha",
        evidence_path: evidence_path
      )

      evidence = runner.call

      assert_equal evidence, JSON.parse(File.read(evidence_path))
      assert_equal(
        [ "hive-live-workflow-creator-evidence", 1, "openclaw", "failed" ],
        evidence.values_at("schema", "schema_version", "platform", "result")
      )
      assert_equal "preflight", evidence.fetch("phase")
      assert_equal "invalid_candidate_sha", evidence.fetch("reason")
      assert_equal(
        {
          "name" => "openai",
          "model" => "openai/gpt-5.6",
          "credential_environment" => "OPENAI_API_KEY"
        },
        evidence.fetch("provider")
      )
      assert_equal %w[audit_gateway candidate openclaw], evidence.fetch("executables").keys.sort
      assert_equal "not_started", evidence.dig("teardown", "status")
      assert_equal "passed", evidence.dig("cleanup", "status")
      assert_operator evidence.fetch("detail").bytesize, :<=, 1_000
      refute_includes JSON.generate(evidence), CREDENTIAL
    end
  end

  def test_preparation_driver_retains_every_typed_failure_partition
    HiveLiveAgentProof::WorkflowCreatorEvidenceDriver::PHASE_REASONS.each do |phase, reasons|
      reasons.each do |reason|
        with_tmp_dir do |dir|
          path = File.join(dir, "evidence.json")
          driver = HiveLiveAgentProof::WorkflowCreatorEvidenceDriver.new(
            path: path,
            candidate_sha: SHA,
            model: "openai/gpt-5.6"
          )
          driver.initialize_evidence!
          driver.fail_partition!(
            phase: phase,
            reason: reason,
            detail: "partition failed"
          )

          evidence = JSON.parse(File.read(path))
          assert_equal "hive-live-workflow-creator-evidence", evidence.fetch("schema")
          assert_equal 1, evidence.fetch("schema_version")
          assert_equal "failed", evidence.fetch("result")
          assert_equal phase, evidence.fetch("phase")
          assert_equal reason, evidence.fetch("reason")
          assert_equal "passed", evidence.dig("secret_scan", "status")
        end
      end
    end
  end

  def test_provider_is_derived_from_model_and_child_gets_exactly_one_named_secret
    base_environment = {
      "PATH" => "/proof/bin",
      "LANG" => "C.UTF-8",
      "OPENAI_API_KEY" => "opposite-secret",
      "OPENROUTER_API_KEY" => "stale-selected-secret",
      "HIVE_LIVE_PROVIDER_CREDENTIAL" => "must-not-reach-child",
      "UNRELATED_SECRET" => "must-not-reach-child"
    }
    runner = build_runner(
      model: "openrouter/openai/gpt-5.6",
      base_environment: base_environment
    )

    provider = runner.provider
    child = runner.child_environment(
      "HOME" => "/proof/home",
      "OPENCLAW_CONFIG_PATH" => "/proof/openclaw.json"
    )

    assert_equal "openrouter", provider.fetch("name")
    assert_equal "OPENROUTER_API_KEY", provider.fetch("credential_environment")
    assert_equal CREDENTIAL, child.fetch("OPENROUTER_API_KEY")
    refute child.key?("OPENAI_API_KEY")
    refute child.key?("HIVE_LIVE_PROVIDER_CREDENTIAL")
    refute child.key?("UNRELATED_SECRET")
    assert_equal "/proof/bin", child.fetch("PATH")
    assert_equal "/proof/home", child.fetch("HOME")
  end

  def test_provider_rejects_unsupported_model_without_leaking_credential
    with_tmp_dir do |dir|
      evidence_path = File.join(dir, "evidence.json")
      runner = build_runner(
        model: "anthropic/claude-opus",
        evidence_path: evidence_path
      )

      evidence = runner.call

      assert_equal "preflight", evidence.fetch("phase")
      assert_equal "unsupported_provider", evidence.fetch("reason")
      assert_equal "unresolved", evidence.dig("provider", "name")
      refute_includes File.read(evidence_path), CREDENTIAL
    end
  end

  def test_missing_model_writes_a_distinct_preflight_reason
    with_tmp_dir do |dir|
      evidence = build_runner(
        model: "",
        evidence_path: File.join(dir, "evidence.json")
      ).call

      assert_equal "preflight", evidence.fetch("phase")
      assert_equal "missing_model", evidence.fetch("reason")
      assert_equal "passed", evidence.dig("cleanup", "status")
    end
  end

  def test_missing_generic_credential_writes_typed_failure
    with_tmp_dir do |dir|
      runner = HiveLiveAgentProof::OpenClawCreatorProof::Runner.new(
        candidate_sha: SHA,
        artifact_dir: "/proof/artifacts",
        evidence_path: File.join(dir, "evidence.json"),
        model: "openrouter/openai/gpt-5.6",
        provider_credential: "",
        candidate_install_receipt: "/proof/candidate-installation-receipt.json",
        openclaw_install_receipt: "/proof/openclaw-installation-receipt.json",
        base_environment: {}
      )

      evidence = runner.call

      assert_equal "missing_provider_credential", evidence.fetch("reason")
      assert_equal "OPENROUTER_API_KEY", evidence.dig("provider", "credential_environment")
    end
  end

  def test_installation_receipts_reject_executable_lock_and_root_tampering
    with_tmp_dir do |dir|
      candidate_root = File.join(dir, "candidate-install")
      openclaw_root = File.join(dir, "openclaw-install")
      FileUtils.mkdir_p([ candidate_root, openclaw_root ])
      candidate = File.join(candidate_root, "hive")
      openclaw = File.join(openclaw_root, "openclaw")
      artifact = File.join(dir, "hive.gem")
      write_executable(candidate, "#!#{RbConfig.ruby}\n")
      write_executable(openclaw, "#!#{RbConfig.ruby}\n")
      File.write(artifact, "candidate artifact")
      receipts = write_installation_receipts(
        dir,
        candidate_path: candidate,
        candidate_artifact: artifact,
        openclaw_path: openclaw
      )

      FileUtils.chmod(0o700, candidate)
      File.open(candidate, "a") { |file| file.write("# changed\n") }
      executable_evidence = build_runner(
        evidence_path: File.join(dir, "executable-evidence.json"),
        candidate_install_receipt: receipts.fetch("candidate"),
        openclaw_install_receipt: receipts.fetch("openclaw")
      ).call
      assert_equal "candidate_installation_receipt_invalid",
                   executable_evidence.fetch("reason")

      write_executable(candidate, "#!#{RbConfig.ruby}\n")
      receipts = write_installation_receipts(
        dir,
        candidate_path: candidate,
        candidate_artifact: artifact,
        openclaw_path: openclaw
      )
      openclaw_receipt = JSON.parse(File.read(receipts.fetch("openclaw")))
      FileUtils.chmod(0o600, openclaw_receipt.dig("lock", "path"))
      File.open(openclaw_receipt.dig("lock", "path"), "a") { |file| file.write("\n") }
      lock_evidence = build_runner(
        evidence_path: File.join(dir, "lock-evidence.json"),
        candidate_install_receipt: receipts.fetch("candidate"),
        openclaw_install_receipt: receipts.fetch("openclaw")
      ).call
      assert_equal "openclaw_installation_receipt_invalid", lock_evidence.fetch("reason")

      outside = File.join(dir, "outside-openclaw")
      write_executable(outside, "#!#{RbConfig.ruby}\n")
      lock_path = File.join(openclaw_root, "package-lock.json")
      FileUtils.cp(
        HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_LOCK_PATH,
        lock_path
      )
      HiveLiveAgentProof::OpenClawCreatorProof::InstallationReceipt.write(
        path: receipts.fetch("openclaw"),
        kind: "openclaw_npm",
        artifact_path: lock_path,
        install_root: openclaw_root,
        executable_path: outside,
        package_name: "openclaw",
        package_version: HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
        package_integrity: HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY,
        lock_path: lock_path,
        package_count:
          HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_LOCK_PACKAGE_COUNT
      )
      root_evidence = build_runner(
        evidence_path: File.join(dir, "root-evidence.json"),
        candidate_install_receipt: receipts.fetch("candidate"),
        openclaw_install_receipt: receipts.fetch("openclaw")
      ).call
      assert_equal "openclaw_installation_receipt_invalid", root_evidence.fetch("reason")
    end
  end

  def test_installation_receipt_writer_cli_emits_a_valid_candidate_receipt
    with_tmp_dir do |dir|
      install_root = File.join(dir, "install")
      FileUtils.mkdir_p(install_root)
      executable = File.join(install_root, "hive")
      artifact = File.join(dir, "hive.gem")
      receipt = File.join(dir, "candidate.json")
      write_executable(executable, "#!#{RbConfig.ruby}\n")
      File.write(artifact, "candidate artifact")
      script = File.expand_path(
        "../../../packaging/live_agent_skills/write_installation_receipt.rb",
        __dir__
      )

      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        script,
        "--output", receipt,
        "--kind", "candidate_gem",
        "--artifact", artifact,
        "--install-root", install_root,
        "--executable", executable,
        "--package-name", "hive-cli",
        "--package-version", Hive::VERSION
      )

      assert status.success?, stderr
      resolved = HiveLiveAgentProof::OpenClawCreatorProof::InstallationReceipt.new(
        path: receipt,
        expected_kind: "candidate_gem",
        expected_package_name: "hive-cli",
        expected_package_version: Hive::VERSION
      ).call
      assert_equal "candidate_gem", resolved.fetch("kind")
      assert_equal File.realpath(executable), resolved.fetch("realpath")
      assert_equal Digest::SHA256.file(artifact).hexdigest,
                   resolved.fetch("artifact_sha256")
    end
  end

  def test_installation_receipt_binds_complete_tree_and_interpreter_identity
    with_tmp_dir do |dir|
      install_root = File.join(dir, "install")
      FileUtils.mkdir_p(File.join(install_root, "lib"))
      executable = File.join(install_root, "hive")
      inner_runtime = File.join(install_root, "lib", "runtime.rb")
      interpreter = File.join(dir, "proof-ruby")
      artifact = File.join(dir, "hive.gem")
      receipt = File.join(dir, "candidate.json")
      write_executable(executable, "#!#{interpreter}\n")
      write_executable(interpreter, "#!/bin/sh\necho 'proof ruby 3.4.0'\n")
      File.write(inner_runtime, "RUNTIME = :original\n")
      File.write(artifact, "candidate artifact")

      HiveLiveAgentProof::OpenClawCreatorProof::InstallationReceipt.write(
        path: receipt,
        kind: "candidate_gem",
        artifact_path: artifact,
        install_root: install_root,
        executable_path: executable,
        interpreter_path: interpreter,
        package_name: "hive-cli",
        package_version: Hive::VERSION
      )
      resolver = lambda do
        HiveLiveAgentProof::OpenClawCreatorProof::InstallationReceipt.new(
          path: receipt,
          expected_kind: "candidate_gem",
          expected_package_name: "hive-cli",
          expected_package_version: Hive::VERSION
        ).call
      end

      resolved = resolver.call
      assert_match(/\A[0-9a-f]{64}\z/, resolved.dig("tree_manifest", "sha256"))
      assert_equal File.realpath(interpreter), resolved.dig("interpreter", "realpath")
      assert_equal "proof ruby 3.4.0", resolved.dig("interpreter", "version")

      FileUtils.chmod(0o600, inner_runtime)
      File.open(inner_runtime, "a") { |file| file.write("MUTATED = true\n") }
      tree_error = assert_raises(HiveLiveAgentProof::Error) { resolver.call }
      assert_includes tree_error.message, "installed tree"

      File.write(inner_runtime, "RUNTIME = :original\n")
      FileUtils.chmod(0o444, inner_runtime)
      FileUtils.chmod(0o700, interpreter)
      File.open(interpreter, "a") { |file| file.write("# changed\n") }
      interpreter_error = assert_raises(HiveLiveAgentProof::Error) { resolver.call }
      assert_includes interpreter_error.message, "interpreter"
    end
  end

  def test_pinned_openclaw_env_shebang_is_invoked_through_receipt_interpreter
    with_tmp_dir do |dir|
      install_root = File.join(dir, "openclaw-install")
      FileUtils.mkdir_p(install_root)
      executable = File.join(install_root, "openclaw.mjs")
      artifact = File.join(dir, "package-lock.json")
      receipt_path = File.join(dir, "openclaw-receipt.json")
      write_executable(
        executable,
        "#!/usr/bin/env node\nconsole.log('OpenClaw pinned beta fixture')\n"
      )
      File.write(artifact, "{}\n")

      receipt = HiveLiveAgentProof::OpenClawCreatorProof::InstallationReceipt.write(
        path: receipt_path,
        kind: "openclaw_npm",
        artifact_path: artifact,
        install_root: install_root,
        executable_path: executable,
        package_name: "openclaw",
        package_version: HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
        package_integrity: HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY,
        interpreter_path: node_executable
      )
      resolved = receipt.fetch("executable").merge(
        "interpreter" => receipt.fetch("interpreter"),
        "launcher_interpreter" => receipt.fetch("launcher_interpreter")
      )
      executor = HiveLiveAgentProof::OpenClawCreatorProof::ProofExecutor.new(
        root: dir,
        candidate: {},
        openclaw: resolved,
        git: {},
        candidate_sha: SHA,
        artifact_dir: dir,
        model: "openai/gpt-5.6",
        environment_policy: nil,
        document: nil,
        process_runner: nil
      )

      assert_nil resolved.fetch("launcher_interpreter")
      assert_equal(
        [ File.realpath(node_executable), File.realpath(executable), "--version" ],
        executor.send(:openclaw_argv, "--version")
      )
    end
  end

  def test_from_env_consumes_only_typed_installation_receipts
    with_tmp_dir do |dir|
      evidence = HiveLiveAgentProof::OpenClawCreatorProof::Runner.from_env(
        "HIVE_CANDIDATE_SHA" => SHA,
        "HIVE_PROOF_ARTIFACTS" => File.join(dir, "missing-artifacts"),
        "HIVE_CREATOR_EVIDENCE_PATH" => File.join(dir, "evidence.json"),
        "HIVE_LIVE_MODEL" => "openai/gpt-5.6",
        "HIVE_LIVE_PROVIDER_CREDENTIAL" => CREDENTIAL,
        "HIVE_CANDIDATE_INSTALL_RECEIPT" => File.join(dir, "missing-candidate.json"),
        "HIVE_OPENCLAW_INSTALL_RECEIPT" => File.join(dir, "missing-openclaw.json"),
        "HIVE_PROVEN_HIVE_BIN" => File.join(dir, "missing-hive"),
        "HIVE_OPENCLAW_BIN" => File.join(dir, "missing-openclaw"),
        "HIVE_OPENCLAW_PACKAGE_VERSION" =>
          HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
        "HIVE_OPENCLAW_PACKAGE_INTEGRITY" =>
          HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY
      ).call

      assert_equal "candidate_installation_receipt_invalid", evidence.fetch("reason")
      assert_equal false, evidence.dig("openclaw_package", "verified")
    end
  end

  def test_missing_candidate_binary_is_reported_before_artifact_work
    with_tmp_dir do |dir|
      candidate_root = File.join(dir, "candidate-install")
      openclaw_root = File.join(dir, "openclaw-install")
      FileUtils.mkdir_p([ candidate_root, openclaw_root ])
      candidate = File.join(candidate_root, "hive")
      openclaw = File.join(openclaw_root, "openclaw")
      artifact = File.join(dir, "hive.gem")
      write_executable(candidate, "#!#{RbConfig.ruby}\n")
      write_executable(openclaw, "#!#{RbConfig.ruby}\n")
      File.write(artifact, "candidate artifact")
      receipts = write_installation_receipts(
        dir,
        candidate_path: candidate,
        candidate_artifact: artifact,
        openclaw_path: openclaw
      )
      FileUtils.chmod(0o700, candidate_root)
      FileUtils.rm_f(candidate)
      evidence = build_runner(
        evidence_path: File.join(dir, "evidence.json"),
        candidate_install_receipt: receipts.fetch("candidate"),
        openclaw_install_receipt: receipts.fetch("openclaw")
      ).call

      assert_equal "candidate_installation_receipt_invalid", evidence.fetch("reason")
      assert_nil evidence.dig("executables", "candidate", "sha256")
    end
  end

  def test_missing_artifact_directory_is_typed_after_executable_identity
    with_tmp_dir do |dir|
      candidate_root = File.join(dir, "candidate-install")
      openclaw_root = File.join(dir, "openclaw-install")
      FileUtils.mkdir_p([ candidate_root, openclaw_root ])
      candidate = File.join(candidate_root, "hive")
      openclaw = File.join(openclaw_root, "openclaw")
      artifact = File.join(dir, "hive.gem")
      write_executable(candidate, "#!#{RbConfig.ruby}\n")
      write_executable(openclaw, "#!#{RbConfig.ruby}\n")
      File.write(artifact, "candidate artifact")
      receipts = write_installation_receipts(
        dir,
        candidate_path: candidate,
        candidate_artifact: artifact,
        openclaw_path: openclaw
      )
      evidence = build_runner(
        artifact_dir: File.join(dir, "missing-artifacts"),
        evidence_path: File.join(dir, "evidence.json"),
        candidate_install_receipt: receipts.fetch("candidate"),
        openclaw_install_receipt: receipts.fetch("openclaw")
      ).call

      assert_equal "artifact_directory_missing", evidence.fetch("reason")
      assert_match(/\A[0-9a-f]{64}\z/, evidence.dig("executables", "candidate", "sha256"))
      assert_match(/\A[0-9a-f]{64}\z/, evidence.dig("executables", "openclaw", "sha256"))
    end
  end

  def test_candidate_receipt_must_bind_the_manifested_gem
    with_tmp_dir do |dir|
      artifacts = prepare_candidate_artifacts(dir)
      candidate_root = File.join(dir, "candidate-install")
      openclaw_root = File.join(dir, "openclaw-install")
      FileUtils.mkdir_p([ candidate_root, openclaw_root ])
      candidate = File.join(candidate_root, "hive")
      openclaw = File.join(openclaw_root, "openclaw")
      substituted_artifact = File.join(dir, "substituted.gem")
      write_executable(candidate, "#!#{RbConfig.ruby}\n")
      write_executable(openclaw, "#!#{RbConfig.ruby}\n")
      File.write(substituted_artifact, "substituted artifact")
      receipts = write_installation_receipts(
        dir,
        candidate_path: candidate,
        candidate_artifact: substituted_artifact,
        openclaw_path: openclaw
      )

      evidence = build_runner(
        artifact_dir: artifacts,
        evidence_path: File.join(dir, "evidence.json"),
        candidate_install_receipt: receipts.fetch("candidate"),
        openclaw_install_receipt: receipts.fetch("openclaw"),
        base_environment: { "PATH" => ENV.fetch("PATH") }
      ).call

      assert_equal "artifact_verification", evidence.fetch("phase")
      assert_equal "candidate_installation_receipt_mismatch", evidence.fetch("reason")
      assert_equal "passed", evidence.dig("cleanup", "status")
    end
  end

  def test_failure_detail_is_redacted_and_byte_bounded
    with_tmp_dir do |dir|
      evidence_path = File.join(dir, "evidence.json")
      runner = build_runner(
        candidate_sha: "#{CREDENTIAL}#{"x" * 2_000}",
        evidence_path: evidence_path
      )

      evidence = runner.call

      assert_equal "invalid_candidate_sha", evidence.fetch("reason")
      assert_operator evidence.fetch("detail").bytesize, :<=, 1_000
      refute_includes evidence.fetch("detail"), CREDENTIAL
      assert_includes evidence.fetch("detail"), "[REDACTED]"
    end
  end

  def test_materializer_accepts_legal_dot_root_and_writes_only_regular_files
    with_tmp_dir do |dir|
      archive = File.join(dir, "skills.tar.gz")
      write_archive(
        archive,
        [ :directory, "./" ],
        [ :directory, "./openclaw/" ],
        [ :directory, "./openclaw/hive/" ],
        [ :file, "./openclaw/hive/SKILL.md", "proof skill\n" ]
      )
      destination = File.join(dir, "materialized")

      records = HiveLiveAgentProof::OpenClawCreatorProof::SafeTarMaterializer.new(
        archive: archive,
        destination: destination
      ).call

      assert_equal [ "openclaw/hive/SKILL.md" ], records.keys
      assert_equal "proof skill\n", File.read(File.join(destination, "openclaw/hive/SKILL.md"))
      refute File.symlink?(File.join(destination, "openclaw"))
    end
  end

  def test_materializer_rejects_traversal_duplicates_and_links
    cases = {
      "traversal" => [
        [ :file, "../outside", "escape" ]
      ],
      "backslash_traversal" => [
        [ :file, '..\outside', "escape" ]
      ],
      "duplicate" => [
        [ :file, "./openclaw/hive/SKILL.md", "one" ],
        [ :file, "openclaw/hive/SKILL.md", "two" ]
      ],
      "symlink" => [
        [ :symlink, "openclaw/hive/SKILL.md", "/etc/passwd" ]
      ]
    }

    cases.each do |name, entries|
      with_tmp_dir do |dir|
        archive = File.join(dir, "#{name}.tar.gz")
        write_archive(archive, *entries)

        error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
          HiveLiveAgentProof::OpenClawCreatorProof::SafeTarMaterializer.new(
            archive: archive,
            destination: File.join(dir, "materialized")
          ).call
        end

        assert_equal "archive", error.phase
        assert_match(/unsafe|duplicate|unsupported/, error.message)
        refute File.exist?(File.join(dir, "outside"))
      end
    end
  end

  def test_materializer_rejects_entry_directory_depth_and_inode_budgets_and_cleans_up
    cases = {
      "entries" => Array.new(HiveLiveAgentProof::SKILL_ARCHIVE_ENTRY_LIMIT + 1) do |index|
        [ :file, "openclaw/hive/files/#{index}", "" ]
      end,
      "directories" => Array.new(HiveLiveAgentProof::SKILL_ARCHIVE_DIRECTORY_LIMIT + 1) do |index|
        [ :directory, "openclaw/hive/directories/#{index}/" ]
      end,
      "depth" => [
        [
          :file,
          (Array.new(HiveLiveAgentProof::SKILL_ARCHIVE_DEPTH_LIMIT + 1, "nested") + [ "file" ]).join("/"),
          ""
        ]
      ],
      "inodes" => Array.new(HiveLiveAgentProof::SKILL_ARCHIVE_INODE_LIMIT + 1) do |index|
        [ :file, "openclaw/hive/inodes/#{index}", "" ]
      end
    }

    cases.each do |name, entries|
      with_tmp_dir do |dir|
        archive = File.join(dir, "#{name}.tar.gz")
        destination = File.join(dir, "materialized")
        write_archive(archive, *entries)

        error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
          HiveLiveAgentProof::OpenClawCreatorProof::SafeTarMaterializer.new(
            archive: archive,
            destination: destination
          ).call
        end

        assert_equal "unsafe_archive", error.reason
        refute File.exist?(destination), "#{name} failure must remove its partial tree"
      end
    end
  end

  def test_materializer_rejects_absolute_hardlink_device_and_fifo_entries
    cases = {
      "absolute" => [ "/absolute", "0", "" ],
      "windows_absolute" => [ "C:/absolute", "0", "" ],
      "hardlink" => [ "openclaw/hive/SKILL.md", "1", "target" ],
      "character_device" => [ "openclaw/hive/device", "3", "" ],
      "block_device" => [ "openclaw/hive/device", "4", "" ],
      "fifo" => [ "openclaw/hive/fifo", "6", "" ]
    }

    cases.each do |name, (entry_name, typeflag, linkname)|
      with_tmp_dir do |dir|
        archive = File.join(dir, "#{name}.tar.gz")
        write_raw_archive(
          archive,
          name: entry_name,
          typeflag: typeflag,
          linkname: linkname
        )

        error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
          HiveLiveAgentProof::OpenClawCreatorProof::SafeTarMaterializer.new(
            archive: archive,
            destination: File.join(dir, "materialized")
          ).call
        end

        assert_equal "unsafe_archive", error.reason
        refute File.exist?(File.join(dir, "materialized"))
      end
    end
  end

  def test_openclaw_configuration_uses_native_path_prepend_without_relabeling_candidate
    with_tmp_dir do |dir|
      workspace = File.join(dir, "workspace")
      gateway_bin = File.join(dir, "gateway", "bin")
      FileUtils.mkdir_p([ workspace, gateway_bin ])
      write_executable(File.join(gateway_bin, "hive"), "#!#{RbConfig.ruby}\n")
      configuration =
        HiveLiveAgentProof::OpenClawCreatorProof::OpenClawConfiguration.new(
          root: dir,
          workspace: workspace,
          model: "openrouter/openai/gpt-5.6",
          gateway_bin_dir: gateway_bin
        )

      payload = configuration.write

      assert_equal [ gateway_bin ], payload.dig("tools", "exec", "pathPrepend")
      assert_equal %w[read write edit apply_patch exec], payload.dig("tools", "allow")
      assert_equal true, payload.dig("tools", "fs", "workspaceOnly")
      assert_equal false, payload.dig("tools", "elevated", "enabled")
      assert_equal true, payload.dig("tools", "exec", "applyPatch", "enabled")
      assert_equal true, payload.dig("tools", "exec", "applyPatch", "workspaceOnly")
      assert_equal "allowlist", payload.dig("tools", "exec", "mode")
      assert_equal "gateway", payload.dig("tools", "exec", "host")
      assert_equal true, payload.dig("tools", "exec", "strictInlineEval")
      assert_equal workspace, payload.dig("agents", "defaults", "workspace")
      assert_equal "openrouter/openai/gpt-5.6",
                   payload.dig("agents", "defaults", "model", "primary")
      assert_equal payload, JSON.parse(File.read(configuration.config_path))
      approvals = JSON.parse(File.read(configuration.approvals_path))
      assert_equal "deny", approvals.dig("defaults", "security")
      assert_equal "allowlist", approvals.dig("agents", "main", "security")
      assert_equal false, approvals.dig("agents", "main", "autoAllowSkills")
      allowlist = approvals.dig("agents", "main", "allowlist")
      assert_equal [ File.join(gateway_bin, "hive") ],
                   allowlist.map { |row| row.fetch("pattern") }
      refute allowlist.first.key?("source")
    end
  end

  def test_audit_gateway_binds_real_candidate_digest_and_exact_command_order
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      calls = File.join(dir, "candidate-calls.jsonl")
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        forbidden = %w[
          OPENAI_API_KEY OPENROUTER_API_KEY HIVE_LIVE_PROVIDER_CREDENTIAL
        ].select { |name| ENV.key?(name) }
        abort "credential reached candidate: \#{forbidden.join(",")}" unless forbidden.empty?
        File.open(#{calls.dump}, "a", 0o600) { |file| file.puts(JSON.generate(ARGV)) }
        puts "candidate:\#{ARGV.join(" ")}"
      RUBY
      audit = File.join(dir, "audit.jsonl")
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        commands: HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.first(2)
      ).install

      credential_environment = {
        "OPENAI_API_KEY" => "selected",
        "OPENROUTER_API_KEY" => "opposite",
        "HIVE_LIVE_PROVIDER_CREDENTIAL" => "generic"
      }
      first_out, first_err, first_status = Open3.capture3(
        credential_environment, gateway, "version"
      )
      second_out, second_err, second_status = Open3.capture3(
        credential_environment, gateway, "workflow", "list", "--json"
      )

      assert first_status.success?, first_err
      assert second_status.success?, second_err
      assert_equal "candidate:version\n", first_out
      assert_equal "candidate:workflow list --json\n", second_out
      assert_equal(
        HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.first(2),
        terminal_audit_rows(audit).map { |row| row.fetch("argv") }
      )
      assert_equal(
        HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.first(2),
        File.readlines(calls, chomp: true).map { |line| JSON.parse(line) }
      )
      receipts = audit_rows(audit)
      assert_equal 4, receipts.length
      assert_equal %w[attempted terminal attempted terminal],
                   receipts.map { |row| row.fetch("phase") }
      assert_attempt_pairs(receipts, expected_decisions: %w[succeeded succeeded])
      assert terminal_audit_rows(audit).all? { |row|
        row["success"] == true && row["exit_status"] == 0 && row["signal"].nil?
      }
      runtime = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "second-gateway"),
        audit_path: File.join(dir, "second-audit.jsonl"),
        commands: [ [ "version" ] ]
      )
      runtime.install
      bundle = runtime.gateway_record.fetch("runtime_bundle")
      assert_equal "hive-openclaw-audit-gateway-runtime", bundle.fetch("schema")
      assert_match(/\A[0-9a-f]{64}\z/, bundle.fetch("config_sha256"))
      assert_match(/\A[0-9a-f]{64}\z/, bundle.fetch("manifest_sha256"))
      assert_equal %w[
        attempt_ledger.rb candidate_executor.rb candidate_identity.rb main.rb result_ledger.rb
        task_binding.rb
      ], bundle.fetch("files").map { |row| row.fetch("name") }.sort
      refute_equal File.realpath(candidate), File.realpath(gateway)
    end
  end

  def test_audit_gateway_holds_serialization_until_candidate_completion
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      first_started = File.join(dir, "first-started")
      first_release = File.join(dir, "first-release")
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        if ARGV == ["version"]
          File.write(#{first_started.dump}, "ready")
          sleep 0.01 until File.file?(#{first_release.dump})
        end
        puts ARGV.join(" ")
      RUBY
      audit = File.join(dir, "audit.jsonl")
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        commands: HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.first(2)
      ).install

      first = Thread.new { Open3.capture3(gateway, "version") }
      sleep 0.01 until File.file?(first_started)
      second = Thread.new { Open3.capture3(gateway, "workflow", "list", "--json") }
      sleep 0.05

      rows_during_execution = audit_rows(audit)
      assert_equal [ "attempted" ], rows_during_execution.map { |row| row.fetch("phase") }
      assert_equal [ "version" ], rows_during_execution.fetch(0).fetch("argv")
      assert second.alive?, "the next command must wait for the active audit transaction"

      File.write(first_release, "go")
      first_out, first_err, first_status = first.value
      second_out, second_err, second_status = second.value

      assert first_status.success?, "#{first_out}\n#{first_err}"
      assert second_status.success?, "#{second_out}\n#{second_err}"
      rows = audit_rows(audit)
      assert_equal [ 1, 1, 2, 2 ], rows.map { |row| row.fetch("ordinal") }
      assert_attempt_pairs(rows, expected_decisions: %w[succeeded succeeded])
    end
  end

  def test_audit_gateway_records_wrong_order_and_terminally_poisons_the_session
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      marker = File.join(dir, "candidate-ran")
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{marker.dump}, "ran")
      RUBY
      audit = File.join(dir, "audit.jsonl")
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        commands: HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.first(2)
      ).install

      _stdout, stderr, status = Open3.capture3(gateway, "workflow", "list", "--json")
      _retry_stdout, retry_stderr, retry_status = Open3.capture3(gateway, "version")

      assert_equal 64, status.exitstatus
      assert_includes stderr, "expected [\"version\"]"
      assert_equal 68, retry_status.exitstatus
      assert_includes retry_stderr, "prior denied or failed attempt"
      refute File.exist?(marker)
      rows = audit_rows(audit)
      assert_equal 2, rows.length, "poisoned retries must not add another attempt"
      assert_attempt_pairs(rows, expected_decisions: [ "denied" ])
      terminal = rows.fetch(1)
      assert_equal "wrong_order", terminal.fetch("reason")
      assert_equal false, terminal.fetch("success")
    end
  end

  def test_audit_gateway_refuses_candidate_bytes_changed_after_install
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        puts "original"
      RUBY
      audit = File.join(dir, "audit.jsonl")
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        commands: [ [ "version" ] ]
      ).install
      File.open(candidate, "a") { |file| file.write("\n# changed\n") }

      _stdout, stderr, status = Open3.capture3(gateway, "version")

      assert_equal 65, status.exitstatus
      assert_includes stderr, "candidate digest changed"
      rows = audit_rows(audit)
      assert_attempt_pairs(rows, expected_decisions: [ "denied" ])
      terminal = rows.fetch(1)
      assert_equal "candidate_digest_drift", terminal.fetch("reason")
      assert_equal false, terminal.fetch("success")
    end
  end

  def test_audit_gateway_records_and_rejects_an_extra_attempt
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      write_executable(candidate, "#!#{RbConfig.ruby}\nputs ARGV.join(' ')\n")
      audit = File.join(dir, "audit.jsonl")
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        commands: [ [ "version" ] ]
      ).install

      _stdout, first_stderr, first_status = Open3.capture3(gateway, "version")
      _extra_stdout, extra_stderr, extra_status = Open3.capture3(gateway, "version")

      assert first_status.success?, first_stderr
      assert_equal 64, extra_status.exitstatus
      assert_includes extra_stderr, "command budget is exhausted"
      rows = audit_rows(audit)
      assert_attempt_pairs(rows, expected_decisions: %w[succeeded denied])
      terminals = rows.select { |row| row.fetch("phase") == "terminal" }
      assert_equal [ "completed", "budget_exhausted" ],
                   terminals.map { |row| row.fetch("reason") }
      assert_equal [ true, false ], terminals.map { |row| row.fetch("success") }
    end
  end

  def test_audit_gateway_records_candidate_failure_and_poisons_retry
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      write_executable(candidate, "#!#{RbConfig.ruby}\nexit 9\n")
      audit = File.join(dir, "audit.jsonl")
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        commands: [ [ "version" ] ]
      ).install

      _stdout, _stderr, status = Open3.capture3(gateway, "version")
      _retry_stdout, _retry_stderr, retry_status = Open3.capture3(gateway, "version")
      rows = audit_rows(audit)

      assert_equal 9, status.exitstatus
      assert_equal 68, retry_status.exitstatus
      assert_equal 2, rows.length, "poisoned retries must not add another attempt"
      assert_attempt_pairs(rows, expected_decisions: [ "failed" ])
      assert_equal "candidate_failed", rows.fetch(1).fetch("reason")
      assert_equal false, rows.fetch(1).fetch("success")
    end
  end

  def test_audit_gateway_binds_dynamic_run_to_the_idempotent_created_slug
    with_tmp_dir do |dir|
      fixture = install_result_binding_gateway(dir)
      drive_gateway_prefix(fixture, count: 6)
      slug = fixture.fetch(:slug)
      gateway = fixture.fetch(:gateway)
      run_out, run_err, run_status = Open3.capture3(gateway, "run", slug)
      rows = audit_rows(fixture.fetch(:audit))
      terminals = rows.select { |row| row.fetch("phase") == "terminal" }

      assert run_status.success?, run_err
      assert_equal "run #{slug}\n", run_out
      assert_equal HiveLiveAgentProof.workflow_creator_commands(slug).first(7),
                   terminals.map { |row| row.fetch("argv") }
      assert_equal slug, terminals.fetch(6).fetch("dynamic_slug")
      assert_equal "succeeded", terminals.fetch(5).fetch("decision")
      assert_equal true,
                   JSON.parse(File.readlines(fixture.fetch(:results)).fetch(1)).fetch("created")
    end
  end

  def test_audit_gateway_refuses_stale_wrong_workflow_and_wrong_result_run_bindings
    variants = {
      "stale metadata after created false" => { created: false },
      "wrong workflow" => { workflow: "default" },
      "wrong task key" => { task_key: "different-idempotency-key" },
      "result slug differs from metadata" => {
        result_slug: "different-created-task-260728-dead"
      }
    }
    variants.each do |label, options|
      with_tmp_dir do |dir|
        fixture = install_result_binding_gateway(dir, **options)
        drive_gateway_prefix(fixture, count: 6)

        _stdout, stderr, status = Open3.capture3(
          fixture.fetch(:gateway), "run", fixture.fetch(:slug)
        )

        assert_equal 66, status.exitstatus, label
        assert_includes stderr, "could not bind one created slug", label
        refute File.exist?(fixture.fetch(:run_marker)), label
        terminal = terminal_audit_rows(fixture.fetch(:audit)).last
        assert_equal "dynamic_binding_failed", terminal.fetch("reason"), label
        assert_equal "denied", terminal.fetch("decision"), label
      end
    end
  end

  def test_audit_gateway_rejects_corrupt_result_ledger_before_dynamic_run
    variants = {
      "extra row" => lambda { |path|
        File.open(path, "a") { |file| file.puts(JSON.generate("unexpected" => true)) }
      },
      "malformed row" => ->(path) { File.open(path, "a") { |file| file.puts("{bad-json") } },
      "wrong attempt binding" => lambda { |path|
        rewrite_result_rows(path) {
          |rows| rows.tap { |items| items.fetch(1)["attempt_id"] = "f" * 64 }
        }
      },
      "wrong result type" => lambda { |path|
        rewrite_result_rows(path) {
          |rows| rows.tap { |items| items.fetch(1)["created"] = "true" }
        }
      },
      "wrong result order" => ->(path) { rewrite_result_rows(path, &:reverse) },
      "symlink target" => lambda { |path|
        original = "#{path}.original"
        File.rename(path, original)
        File.symlink(original, path)
      },
      "oversize file" => lambda { |path|
        File.open(path, "a") { |file| file.write("x" * (512 * 1024)) }
      }
    }
    variants.each do |label, mutate|
      with_tmp_dir do |dir|
        fixture = install_result_binding_gateway(dir)
        drive_gateway_prefix(fixture, count: 6)
        mutate.call(fixture.fetch(:results))

        _stdout, stderr, status = Open3.capture3(
          fixture.fetch(:gateway), "run", fixture.fetch(:slug)
        )

        assert_equal 68, status.exitstatus, label
        assert_includes stderr, "result ledger", label
        refute File.exist?(fixture.fetch(:run_marker)), label
        assert_equal 12, audit_rows(fixture.fetch(:audit)).length, label
      end
    end
  end

  def test_audit_gateway_rejects_unconfined_oversize_and_duplicate_task_metadata
    variants = {
      "symlinked task ancestor" => lambda { |fixture|
        task = File.join(
          fixture.fetch(:workspace), ".hive-state", "stages", "1-research",
          fixture.fetch(:slug)
        )
        moved = "#{task}.outside"
        File.rename(task, moved)
        File.symlink(moved, task)
      },
      "oversize metadata" => lambda { |fixture|
        meta = File.join(
          fixture.fetch(:workspace), ".hive-state", "stages", "1-research",
          fixture.fetch(:slug), "meta.yml"
        )
        File.open(meta, "a") { |file| file.write("#" * (128 * 1024)) }
      },
      "duplicate matching metadata" => lambda { |fixture|
        source = File.join(
          fixture.fetch(:workspace), ".hive-state", "stages", "1-research",
          fixture.fetch(:slug), "meta.yml"
        )
        destination = File.join(
          fixture.fetch(:workspace), ".hive-state", "stages", "2-draft",
          fixture.fetch(:slug), "meta.yml"
        )
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination)
      }
    }
    variants.each do |label, mutate|
      with_tmp_dir do |dir|
        fixture = install_result_binding_gateway(dir)
        drive_gateway_prefix(fixture, count: 6)
        mutate.call(fixture)

        _stdout, stderr, status = Open3.capture3(
          fixture.fetch(:gateway), "run", fixture.fetch(:slug)
        )

        assert_equal 66, status.exitstatus, label
        assert_includes stderr, "could not bind one created slug", label
        refute File.exist?(fixture.fetch(:run_marker)), label
      end
    end
  end

  def test_audit_gateway_retains_nine_successful_attempt_pairs_and_bound_results
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      workspace = File.join(dir, "workspace")
      audit = File.join(dir, "audit.jsonl")
      results = File.join(dir, "results.jsonl")
      slug = "research-and-draft-the-launch-260728-abcd"
      calls = File.join(dir, "calls")
      FileUtils.mkdir_p(workspace)
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        require "fileutils"
        require "json"
        require "yaml"
        ordinal = File.file?(#{calls.dump}) ? File.readlines(#{calls.dump}).length + 1 : 1
        File.open(#{calls.dump}, "a", 0o600) { |file| file.puts(JSON.generate(ARGV)) }
        case ordinal
        when 4
          puts JSON.generate(
            "schema" => "hive-workflow-validate",
            "valid" => true,
            "stages" => %w[research draft approval].map { |name| { "name" => name } },
            "automatic_edges" => [
              { "from" => "research", "to" => "draft" },
              { "from" => "draft", "to" => "approval" }
            ],
            "human_outcomes" => []
          )
        when 6
          meta = File.join(
            #{workspace.dump}, ".hive-state", "stages", "1-research",
            #{slug.dump}, "meta.yml"
          )
          FileUtils.mkdir_p(File.dirname(meta))
          File.write(
            meta,
            { "slug" => #{slug.dump},
              "workflow" => "editorial",
              "idempotency_key" => #{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_KEY.dump} }.to_yaml
          )
          puts JSON.generate("schema" => "hive-new", "slug" => #{slug.dump}, "created" => true)
        when 8
          puts JSON.generate("schema" => "hive-new", "slug" => #{slug.dump}, "created" => false)
        else
          puts JSON.generate("ok" => true)
        end
      RUBY
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        result_path: results,
        workspace: workspace
      ).install

      commands = HiveLiveAgentProof.workflow_creator_commands(slug)
      commands.each do |argv|
        _stdout, stderr, status = Open3.capture3(gateway, *argv)
        assert status.success?, "#{argv.inspect}: #{stderr}"
      end

      rows = audit_rows(audit)
      assert_equal 18, rows.length
      assert_attempt_pairs(rows, expected_decisions: Array.new(9, "succeeded"))
      assert_equal commands, terminal_audit_rows(audit).map { |row| row.fetch("argv") }
      result_rows = File.readlines(results, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[validation task_creation task_creation],
                   result_rows.map { |row| row.fetch("kind") }
      assert_equal [ 4, 6, 8 ], result_rows.map { |row| row.fetch("ordinal") }
      paired_ids = terminal_audit_rows(audit).to_h {
        |row| [ row.fetch("ordinal"), row.fetch("attempt_id") ]
      }
      assert_equal result_rows.map { |row| paired_ids.fetch(row.fetch("ordinal")) },
                   result_rows.map { |row| row.fetch("attempt_id") }
    end
  end

  def test_audit_gateway_killed_after_candidate_side_effect_leaves_pending_attempt
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      marker = File.join(dir, "candidate-side-effects")
      audit = File.join(dir, "audit.jsonl")
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        File.open(#{marker.dump}, "a", 0o600) { |file| file.puts("effect") }
        Process.kill("KILL", Process.ppid)
        sleep 0.1
      RUBY
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        commands: [ [ "version" ] ]
      ).install

      _stdout, _stderr, killed = Open3.capture3(gateway, "version")
      _retry_stdout, retry_stderr, retry_status = Open3.capture3(gateway, "version")

      assert killed.signaled?
      assert_equal Signal.list.fetch("KILL"), killed.termsig
      assert_equal 68, retry_status.exitstatus
      assert_includes retry_stderr, "pending attempt"
      rows = audit_rows(audit)
      assert_equal [ "attempted" ], rows.map { |row| row.fetch("phase") }
      assert_equal [ "effect\n" ], File.readlines(marker)
    end
  end

  def test_audit_gateway_rejects_malformed_duplicate_and_mismatched_ledger_rows
    variants = {
      "malformed JSON" => ->(_rows) { [ "{not-json" ] },
      "duplicate phase" => ->(rows) {
        [ JSON.generate(rows.fetch(0)), JSON.generate(rows.fetch(0)), JSON.generate(rows.fetch(1)) ]
      },
      "mismatched attempt id" => ->(rows) {
        terminal = rows.fetch(1).merge("attempt_id" => "a" * 64)
        [ JSON.generate(rows.fetch(0)), JSON.generate(terminal) ]
      }
    }
    variants.each do |label, mutate|
      with_tmp_dir do |dir|
        candidate = File.join(dir, "candidate-hive")
        marker = File.join(dir, "candidate-calls")
        audit = File.join(dir, "audit.jsonl")
        write_executable(candidate, <<~RUBY)
          #!#{RbConfig.ruby}
          File.open(#{marker.dump}, "a", 0o600) { |file| file.puts("call") }
        RUBY
        gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
          candidate_path: candidate,
          directory: File.join(dir, "gateway"),
          audit_path: audit,
          commands: [ [ "version" ], [ "workflow", "list", "--json" ] ]
        ).install
        _stdout, stderr, status = Open3.capture3(gateway, "version")
        assert status.success?, "#{label}: #{stderr}"
        original_rows = audit_rows(audit)
        File.write(audit, "#{mutate.call(original_rows).join("\n")}\n")

        _bad_stdout, bad_stderr, bad_status =
          Open3.capture3(gateway, "workflow", "list", "--json")

        assert_equal 68, bad_status.exitstatus, label
        assert_includes bad_stderr, "audit ledger", label
        assert_equal [ "call\n" ], File.readlines(marker), label
      end
    end
  end

  def test_audit_gateway_rejects_runtime_symlink_digest_and_config_drift
    {
      "runtime digest" => lambda { |gateway_root|
        path = File.join(gateway_root, "runtime", "main.rb")
        FileUtils.chmod(0o600, path)
        File.open(path, "a") { |file| file.write("\n# drift\n") }
      },
      "runtime symlink" => lambda { |gateway_root|
        path = File.join(gateway_root, "runtime", "candidate_executor.rb")
        FileUtils.rm_f(path)
        File.symlink("/dev/null", path)
      },
      "config digest" => lambda { |gateway_root|
        path = File.join(gateway_root, "runtime", "config.json")
        FileUtils.chmod(0o600, path)
        File.open(path, "a") { |file| file.write(" ") }
      }
    }.each do |label, mutate|
      with_tmp_dir do |dir|
        candidate = File.join(dir, "candidate-hive")
        marker = File.join(dir, "candidate-ran")
        gateway_root = File.join(dir, "gateway")
        write_executable(candidate, <<~RUBY)
          #!#{RbConfig.ruby}
          File.write(#{marker.dump}, "ran")
        RUBY
        gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
          candidate_path: candidate,
          directory: gateway_root,
          audit_path: File.join(dir, "audit.jsonl"),
          commands: [ [ "version" ] ]
        )
        gateway_path = gateway.install
        gateway.gateway_record.fetch("runtime_bundle").fetch("files").each do |record|
          assert_equal(
            File.binread(
              File.join(
                HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway::RUNTIME_DIRECTORY,
                record.fetch("name")
              )
            ),
            File.binread(File.join(gateway_root, "runtime", record.fetch("name"))),
            label
          )
        end
        mutate.call(gateway_root)

        _stdout, stderr, status = Open3.capture3(gateway_path, "version")

        assert_equal 69, status.exitstatus, label
        assert_includes stderr, "runtime identity failed", label
        refute File.exist?(marker), label
      end
    end
  end

  def test_proof_inspector_rejects_result_not_bound_to_successful_attempt
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      audit = File.join(dir, "audit.jsonl")
      results = File.join(dir, "results.jsonl")
      write_executable(candidate, "#!#{RbConfig.ruby}\nputs 'ok'\n")
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        result_path: results,
        commands: [ [ "version" ] ]
      )
      gateway_path = gateway.install
      _stdout, stderr, status = Open3.capture3(gateway_path, "version")
      assert status.success?, stderr
      terminal = terminal_audit_rows(audit).fetch(0)
      File.write(
        results,
        "#{JSON.generate(
          "attempt_id" => "f" * 64,
          "ordinal" => terminal.fetch("ordinal"),
          "kind" => "validation"
        )}\n"
      )
      inspector = HiveLiveAgentProof::OpenClawCreatorProof::ProofInspector.new(
        workspace: File.join(dir, "workspace"),
        audit_path: audit,
        result_path: results,
        candidate_record: gateway.candidate_record
      )

      error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
        inspector.send(:result_rows)
      end
      assert_includes error.message, "result ledger"
    end
  end

  def test_socket_receipts_remain_unattributed_and_outside_authorization_adjudication
    with_tmp_dir do |dir|
      workspace = File.join(dir, "workspace")
      policy_path = File.join(dir, "policy.json")
      effects_path = File.join(dir, "effects.json")
      FileUtils.mkdir_p(workspace)
      File.write(
        policy_path,
        JSON.generate(
          "unauthorized_effects_observed" => [],
          "monitored_surfaces" => %w[
            workspace_filesystem configured_tool_inventory
          ],
          "outside_read_caveat" => {
            "caveat" => "Configured skill roots remain readable."
          }
        )
      )
      File.write(
        effects_path,
        JSON.generate(
          "schema" => "hive-live-agent-effect-observation",
          "schema_version" => 1,
          "workspace" => workspace,
          "status" => "observed",
          "observations" => %w[workflow_creation task_creation].map {
            |label| { "label" => label, "status" => "observed", "mutations" => [] }
          }
        )
      )
      process_records = [
        {
          "label" => "workflow_creation",
          "network" => {
            "status" => "observed",
            "sample_count" => 1,
            "sockets" => [
              { "protocol" => "tcp4", "remote" => "0100007F:01BB", "state" => "01" }
            ]
          }
        }
      ]
      inspector = HiveLiveAgentProof::OpenClawCreatorProof::ProofInspector.new(
        workspace: workspace,
        audit_path: File.join(dir, "audit.jsonl"),
        result_path: File.join(dir, "results.jsonl"),
        candidate_record: {},
        policy_path: policy_path,
        effects_path: effects_path,
        process_records: process_records
      )

      network = inspector.send(:observed_network_effects)
      assert_equal [ "unattributed_agent_window" ],
                   network.map { |row| row.fetch("classification") }
      assert_equal [ "workflow_creation" ],
                   network.map { |row| row.fetch("window") }
      assert_equal [], inspector.send(:observed_unauthorized_effects)
      scope = inspector.send(:external_actions_scope)
      assert_equal "unverified", scope.fetch("network_authorization")
      assert_equal [ "process_socket_snapshots" ],
                   scope.fetch("observed_unadjudicated_surfaces")
      refute_includes scope.fetch("monitored_surfaces"), "process_socket_snapshots"
    end
  end

  def test_audit_gateway_fails_closed_for_non_regular_audit_target
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      marker = File.join(dir, "candidate-ran")
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{marker.dump}, "ran")
      RUBY
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: "/dev/full",
        commands: [ [ "version" ] ]
      ).install

      _stdout, stderr, status = Open3.capture3(gateway, "version")

      assert_equal 68, status.exitstatus
      assert_includes stderr, "not a regular file"
      refute File.exist?(marker)
    end
  end

  def test_durable_audit_appender_surfaces_write_and_fsync_failures
    with_tmp_dir do |dir|
      regular_stat = Object.new
      regular_stat.define_singleton_method(:file?) { true }
      failures = {
        "write" => ->(file) {
          file.define_singleton_method(:write) { |_bytes| raise Errno::ENOSPC }
          file.define_singleton_method(:flush) { }
          file.define_singleton_method(:fsync) { }
        },
        "fsync" => ->(file) {
          file.define_singleton_method(:write) { |bytes| bytes.bytesize }
          file.define_singleton_method(:flush) { }
          file.define_singleton_method(:fsync) { raise Errno::EINVAL }
        }
      }
      failures.each do |label, configure|
        fake_file = Object.new
        fake_file.define_singleton_method(:stat) { regular_stat }
        configure.call(fake_file)
        open_file = lambda do |_path, _flags, _mode, &block|
          block.call(fake_file)
        end
        appender =
          HiveLiveAgentProof::OpenClawCreatorGatewayRuntime::DurableJsonLineAppender.new(
            File.join(dir, "#{label}.jsonl"),
            open_file: open_file
          )

        error = assert_raises(
          HiveLiveAgentProof::OpenClawCreatorGatewayRuntime::LedgerWriteFailed
        ) { appender.append("phase" => "attempted") }
        assert_includes error.message, "write/fsync failed"
        assert_includes error.message, label == "write" ? "space" : "Invalid"
      end
    end
  end

  def test_proof_inspector_rejects_extra_authored_files_and_malformed_task_entries
    with_tmp_dir do |dir|
      workspace = File.join(dir, "workspace")
      HiveLiveAgentProof::WORKFLOW_CREATOR_FILES.each do |relative|
        path = File.join(workspace, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "expected\n")
      end
      File.write(
        File.join(workspace, ".hive-state", "workflows", "editorial", "extra.md"),
        "unexpected\n"
      )
      inspector = HiveLiveAgentProof::OpenClawCreatorProof::ProofInspector.new(
        workspace: workspace,
        audit_path: File.join(dir, "audit.jsonl"),
        result_path: File.join(dir, "results.jsonl"),
        candidate_record: { "realpath" => "/proof/hive", "sha256" => "a" * 64 }
      )

      extra_error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
        inspector.send(:created_file_records)
      end
      assert_includes extra_error.message, "missing or extra"

      FileUtils.rm_f(
        File.join(workspace, ".hive-state", "workflows", "editorial", "extra.md")
      )
      malformed = File.join(workspace, ".hive-state", "stages", "1-research", "malformed")
      FileUtils.mkdir_p(malformed)
      task_error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
        inspector.send(:task_folders)
      end
      assert_includes task_error.message, "meta.yml"
    end
  end

  def test_proof_inspector_rejects_symlinks_and_special_entries_in_actual_trees
    with_tmp_dir do |dir|
      workspace = File.join(dir, "workspace")
      HiveLiveAgentProof::WORKFLOW_CREATOR_FILES.each do |relative|
        path = File.join(workspace, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "expected\n")
      end
      workflow_link = File.join(
        workspace, ".hive-state", "workflows", "editorial", "linked.md"
      )
      File.symlink("/etc/passwd", workflow_link)
      inspector = HiveLiveAgentProof::OpenClawCreatorProof::ProofInspector.new(
        workspace: workspace,
        audit_path: File.join(dir, "audit.jsonl"),
        result_path: File.join(dir, "results.jsonl"),
        candidate_record: { "realpath" => "/proof/hive", "sha256" => "a" * 64 }
      )

      link_error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
        inspector.send(:created_file_records)
      end
      assert_includes link_error.message, "symlink"

      FileUtils.rm_f(workflow_link)
      task = File.join(workspace, ".hive-state", "stages", "1-research", "task")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "meta.yml"), YAML.dump("slug" => "task"))
      special = File.join(task, "special")
      File.mkfifo(special, 0o600)
      special_error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
        inspector.send(:task_folders)
      end
      assert_includes special_error.message, "special entry"
    end
  end

  def test_process_runner_scans_all_unredacted_bytes_beyond_retention_limit
    with_tmp_dir do |dir|
      script = File.join(dir, "emit")
      write_executable(script, <<~RUBY)
        #!#{RbConfig.ruby}
        STDOUT.write("x" * 128)
        STDOUT.write(#{CREDENTIAL.dump})
        STDERR.write("done")
      RUBY
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 2,
        term_grace: 0.1,
        output_limit: 16,
        exact_secrets: [ CREDENTIAL ]
      )

      result = runner.call(environment: {}, argv: [ script ], chdir: dir)

      assert result.fetch("status").success?
      assert_equal 16, result.fetch("stdout").bytesize
      assert_operator result.dig("record", "stdout", "bytes"), :>, 128
      assert_includes result.fetch("secret_findings"), "exact-secret:0"
      assert_equal "passed", result.dig("record", "teardown", "status")
      assert_equal true, result.dig("record", "teardown", "reaped")
      assert_equal "complete", result.dig("record", "teardown", "writer")
      assert_equal "none", result.dig("record", "teardown", "descendants")
    end
  end

  def test_framed_json_round_trips_binary_and_rejects_invalid_frames
    codec = HiveLiveAgentProof::OpenClawCreatorProof::FramedJson.new(max_bytes: 256)
    binary = "\x00\xFFproof".b
    reader, writer = IO.pipe
    codec.write(writer, { "frame" => "binary", "bytes_base64" => Base64.strict_encode64(binary) })
    writer.close

    frame = codec.read(reader, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)
    codec.expect_eof!(reader, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)

    assert_equal %w[bytes_base64 frame], frame.keys.sort
    assert_equal binary, Base64.strict_decode64(frame.fetch("bytes_base64"))

    [
      [ [ 999 ].pack("N") + "{}", "oversized" ],
      [ [ 10 ].pack("N") + "{}", "truncated" ],
      [ [ 1 ].pack("N") + "{", "malformed" ],
      [ [ 2 ].pack("N") + "[]", "wrong type" ]
    ].each do |raw, label|
      invalid_reader, invalid_writer = IO.pipe
      invalid_writer.write(raw)
      invalid_writer.close
      assert_raises(
        HiveLiveAgentProof::OpenClawCreatorProof::Failure,
        "#{label} frame must fail closed"
      ) do
        codec.read(
          invalid_reader,
          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        )
      end
    ensure
      invalid_reader&.close
      invalid_writer&.close unless invalid_writer&.closed?
    end

    trailing_reader, trailing_writer = IO.pipe
    codec.write(trailing_writer, { "frame" => "one" })
    codec.write(trailing_writer, { "frame" => "two" })
    trailing_writer.close
    codec.read(
      trailing_reader,
      deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    )
    assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
      codec.expect_eof!(
        trailing_reader,
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      )
    end
  ensure
    reader&.close
    writer&.close unless writer&.closed?
    trailing_reader&.close
    trailing_writer&.close unless trailing_writer&.closed?
  end

  def test_process_runner_worker_stop_is_bounded_and_drains_escaped_descendants
    assert_worker_loss_is_bounded("STOP")
  end

  def test_process_runner_worker_kill_is_bounded_and_drains_escaped_descendants
    assert_worker_loss_is_bounded("KILL")
  end

  def test_stream_capture_detects_literal_and_pattern_secrets_split_across_short_chunks
    literal = "proof-secret-split-across-writes"
    capture = HiveLiveAgentProof::OpenClawCreatorProof::StreamCapture.new(
      limit: 256,
      exact_secrets: [ literal ]
    )
    [ "prefix-", "proof-secret-", "split-", "across-", "writes-suffix" ].each do |chunk|
      capture.update(chunk)
    end

    pattern = HiveLiveAgentProof::OpenClawCreatorProof::StreamCapture.new(
      limit: 256,
      exact_secrets: []
    )
    [ "prefix sk-proj-", "abcdefghijkl", "mnopqrstuvwx suffix" ].each do |chunk|
      pattern.update(chunk)
    end

    assert_includes capture.findings, "exact-secret:0"
    assert pattern.findings.any? { |finding| finding.start_with?("pattern:") }
  end

  def test_process_runner_times_out_with_term_and_reaps_the_group
    with_tmp_dir do |dir|
      marker = File.join(dir, "term-seen")
      script = File.join(dir, "term")
      write_executable(script, <<~RUBY)
        #!#{RbConfig.ruby}
        trap("TERM") { File.write(#{marker.dump}, "term"); exit 0 }
        loop { sleep 1 }
      RUBY
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 0.2,
        term_grace: 0.5,
        output_limit: 64,
        exact_secrets: []
      )

      result = runner.call(environment: {}, argv: [ script ], chdir: dir)

      assert_equal true, result.dig("record", "timed_out")
      assert_equal true, result.dig("record", "teardown", "term_sent")
      assert_equal false, result.dig("record", "teardown", "kill_sent")
      assert_equal true, result.dig("record", "teardown", "reaped")
      assert_equal "none", result.dig("record", "teardown", "descendants")
      assert_equal "term", File.read(marker)
    end
  end

  def test_process_runner_cleans_a_setsid_descendant_left_by_a_successful_parent
    with_tmp_dir do |dir|
      script = File.join(dir, "descendant")
      ready = File.join(dir, "descendant-ready")
      descendant_source =
        "Process.setsid; trap('TERM', 'IGNORE'); File.write(#{ready.dump}, 'ready'); loop { sleep 1 }"
      write_executable(script, <<~RUBY)
        #!#{RbConfig.ruby}
        child = spawn(
          #{RbConfig.ruby.dump}, "-e",
          #{descendant_source.dump},
          out: File::NULL, err: File::NULL
        )
        sleep 0.01 until File.file?(#{ready.dump})
        puts child
      RUBY
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 2,
        term_grace: 0.05,
        output_limit: 64,
        exact_secrets: []
      )

      result = runner.call(environment: {}, argv: [ script ], chdir: dir)

      assert result.fetch("status").success?, result.fetch("stderr")
      refute_empty result.fetch("stdout"), result.inspect
      child_pid = Integer(result.fetch("stdout").strip, 10)
      assert_equal true, result.dig("record", "teardown", "term_sent")
      assert_equal true, result.dig("record", "teardown", "kill_sent")
      assert_equal "none", result.dig("record", "teardown", "descendants")
      assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
    end
  end

  def test_process_runner_cleans_a_double_forked_descendant
    with_tmp_dir do |dir|
      script = File.join(dir, "double-fork")
      ready = File.join(dir, "double-fork-ready")
      pid_path = File.join(dir, "double-fork-pid")
      write_executable(script, <<~RUBY)
        #!#{RbConfig.ruby}
        first = fork do
          Process.setsid
          second = fork do
            trap("TERM", "IGNORE")
            File.write(#{pid_path.dump}, Process.pid.to_s)
            File.write(#{ready.dump}, "ready")
            loop { sleep 1 }
          end
          Process.detach(second)
          exit! 0
        end
        Process.wait(first)
        sleep 0.01 until File.file?(#{ready.dump})
      RUBY
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 2,
        term_grace: 0.1,
        output_limit: 64,
        exact_secrets: []
      )

      result = runner.call(environment: {}, argv: [ script ], chdir: dir)

      assert result.fetch("status").success?, result.fetch("stderr")
      descendant_pid = Integer(File.read(pid_path), 10)
      assert_equal true, result.dig("record", "teardown", "kill_sent")
      assert_equal "none", result.dig("record", "teardown", "descendants")
      assert_raises(Errno::ESRCH) { Process.kill(0, descendant_pid) }
    end
  end

  def test_process_runner_interrupts_through_the_subreaper_and_records_teardown
    with_tmp_dir do |dir|
      script = File.join(dir, "interrupt")
      ready = File.join(dir, "interrupt-ready")
      target_pid = File.join(dir, "interrupt-pid")
      write_executable(script, <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{target_pid.dump}, Process.pid.to_s)
        trap("TERM") { exit 0 }
        File.write(#{ready.dump}, "ready")
        loop { sleep 1 }
      RUBY
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 5,
        term_grace: 0.5,
        output_limit: 64,
        exact_secrets: []
      )

      execution = Thread.new do
        runner.call(environment: {}, argv: [ script ], chdir: dir)
      end
      Timeout.timeout(2) do
        sleep 0.01 until File.file?(ready) && runner.supervisor_pid
      end
      Process.kill("TERM", runner.supervisor_pid)
      result = execution.value

      assert_equal true, result.dig("record", "interrupted")
      assert_equal false, result.dig("record", "timed_out")
      assert_equal true, result.dig("record", "teardown", "term_sent")
      assert_equal "linux_child_subreaper",
                   result.dig("record", "teardown", "containment")
      assert_equal "passed", result.dig("record", "teardown", "status")
      assert_raises(Errno::ESRCH) do
        Process.kill(0, Integer(File.read(target_pid), 10))
      end
    ensure
      if execution&.alive?
        execution.kill
        execution.join(5)
      end
    end
  end

  def test_process_runner_parent_interruption_drains_all_supervisor_descendants
    with_tmp_dir do |dir|
      script = File.join(dir, "parent-interrupt")
      ready = File.join(dir, "parent-interrupt-ready")
      target_pid_path = File.join(dir, "parent-interrupt-target-pid")
      child_pid_path = File.join(dir, "parent-interrupt-child-pid")
      child_source = <<~RUBY
        Process.setsid
        trap("TERM", "IGNORE")
        File.write(#{child_pid_path.dump}, Process.pid.to_s)
        loop { sleep 1 }
      RUBY
      write_executable(script, <<~RUBY)
        #!#{RbConfig.ruby}
        trap("TERM", "IGNORE")
        File.write(#{target_pid_path.dump}, Process.pid.to_s)
        child = spawn(
          #{RbConfig.ruby.dump}, "-e", #{child_source.dump},
          out: File::NULL, err: File::NULL
        )
        sleep 0.01 until File.file?(#{child_pid_path.dump})
        File.write(#{ready.dump}, child.to_s)
        loop { sleep 1 }
      RUBY
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 5,
        term_grace: 0.05,
        output_limit: 64,
        exact_secrets: []
      )
      execution = Thread.new do
        runner.call(environment: {}, argv: [ script ], chdir: dir)
      end
      execution.report_on_exception = false

      Timeout.timeout(2) do
        sleep 0.01 until File.file?(ready) && runner.supervisor_pid
      end
      supervisor_pid = runner.supervisor_pid
      target_pid = Integer(File.read(target_pid_path), 10)
      child_pid = Integer(File.read(child_pid_path), 10)
      execution.raise(Interrupt)

      assert_raises(Interrupt) { execution.value }
      [ supervisor_pid, target_pid, child_pid ].each do |pid|
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      end
    ensure
      if execution&.alive?
        execution.kill
        execution.join(5)
      end
    end
  end

  def test_process_runner_top_level_interrupt_drains_adopted_descendant
    with_tmp_dir do |dir|
      ready = File.join(dir, "top-level-interrupt-ready")
      child_pid_path = File.join(dir, "top-level-interrupt-child-pid")
      child_source = <<~RUBY
        Process.setsid
        trap("TERM", "IGNORE")
        File.write(#{child_pid_path.dump}, Process.pid.to_s)
        loop { sleep 1 }
      RUBY
      worker_factory = lambda do |**_arguments|
        Object.new.tap do |worker|
          worker.define_singleton_method(:call) do |**_options|
            child = spawn(
              RbConfig.ruby, "-e", child_source,
              out: File::NULL, err: File::NULL
            )
            File.write(ready, child.to_s)
            loop { sleep 1 }
          end
        end
      end
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 5,
        term_grace: 0.05,
        output_limit: 64,
        exact_secrets: [],
        worker_factory: worker_factory
      )
      execution = Thread.new do
        runner.call(environment: {}, argv: [ "/unused" ], chdir: dir)
      end
      execution.report_on_exception = false

      Timeout.timeout(2) do
        sleep 0.01 until File.file?(ready) && File.file?(child_pid_path) &&
                               runner.supervisor_pid
      end
      supervisor_pid = runner.supervisor_pid
      child_pid = Integer(File.read(child_pid_path), 10)
      Process.kill("TERM", supervisor_pid)

      error = assert_raises(
        HiveLiveAgentProof::OpenClawCreatorProof::Failure
      ) { execution.value }
      assert_equal "interrupted", error.reason
      [ supervisor_pid, child_pid ].each do |pid|
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      end
    ensure
      if execution&.alive?
        execution.kill
        execution.join(5)
      end
    end
  end

  def test_evidence_document_recursively_redacts_before_persistence
    with_tmp_dir do |dir|
      path = File.join(dir, "evidence.json")
      document = HiveLiveAgentProof::OpenClawCreatorProof::EvidenceDocument.new(
        candidate_sha: SHA,
        model: "openai/gpt-5.6",
        credential: CREDENTIAL
      )
      document.merge!(
        "nested" => {
          "array" => [ "before #{CREDENTIAL} after", "sk-proj-abcdefghijklmnopqrstuvwxyz" ]
        }
      )

      document.finalize_secret_scan
      document.write(path)
      persisted = File.read(path)
      payload = JSON.parse(persisted)

      refute_includes persisted, CREDENTIAL
      refute_includes persisted, "sk-proj-abcdefghijklmnopqrstuvwxyz"
      assert_equal "failed", payload.fetch("result")
      assert_equal "secret_material_detected", payload.fetch("reason")
      assert_equal "failed", payload.dig("secret_scan", "status")
    end
  end

  def test_cleanup_failure_overrides_an_ordinary_failure_and_remains_typed
    with_tmp_dir do |dir|
      candidate_root = File.join(dir, "candidate-install")
      openclaw_root = File.join(dir, "openclaw-install")
      FileUtils.mkdir_p([ candidate_root, openclaw_root ])
      candidate = File.join(candidate_root, "hive")
      openclaw = File.join(openclaw_root, "openclaw")
      artifact = File.join(dir, "hive.gem")
      artifacts = File.join(dir, "artifacts")
      root = File.join(dir, "proof-root")
      FileUtils.mkdir_p([ artifacts, root ])
      write_executable(candidate, "#!#{RbConfig.ruby}\n")
      write_executable(openclaw, "#!#{RbConfig.ruby}\n")
      File.write(artifact, "candidate artifact")
      receipts = write_installation_receipts(
        dir,
        candidate_path: candidate,
        candidate_artifact: artifact,
        openclaw_path: openclaw
      )
      runner = build_runner(
        artifact_dir: artifacts,
        evidence_path: File.join(dir, "evidence.json"),
        candidate_install_receipt: receipts.fetch("candidate"),
        openclaw_install_receipt: receipts.fetch("openclaw"),
        base_environment: { "PATH" => ENV.fetch("PATH") },
        root_factory: -> { root },
        cleanup: ->(_path) { raise Errno::EACCES, "cleanup denied" }
      )

      evidence = runner.call

      assert_equal "failed", evidence.fetch("result")
      assert_equal "cleanup", evidence.fetch("phase")
      assert_equal "cleanup_failed", evidence.fetch("reason")
      assert_equal "failed", evidence.dig("cleanup", "status")
      assert_equal false, evidence.dig("cleanup", "root_removed")
      refute_includes File.read(File.join(dir, "evidence.json")), CREDENTIAL
    end
  end

  def test_runner_drives_fake_openclaw_through_the_real_candidate_and_dynamic_slug
    with_tmp_dir do |dir|
      artifacts = prepare_candidate_artifacts(dir)
      candidate_root = File.join(dir, "candidate-install")
      openclaw_root = File.join(dir, "openclaw-install")
      FileUtils.mkdir_p([ candidate_root, openclaw_root ])
      openclaw = File.join(openclaw_root, "openclaw")
      candidate = File.join(candidate_root, "candidate-hive")
      bundle_executable = Gem.bin_path("bundler", "bundle")
      write_fake_openclaw(openclaw)
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        forbidden = %w[
          OPENAI_API_KEY OPENROUTER_API_KEY HIVE_LIVE_PROVIDER_CREDENTIAL
        ].select { |name| ENV.key?(name) }
        abort "provider credential reached candidate: \#{forbidden.join(",")}" unless forbidden.empty?
        ENV["GEM_HOME"] = #{Gem.dir.dump}
        ENV["GEM_PATH"] = #{Gem.path.join(File::PATH_SEPARATOR).dump}
        ENV["BUNDLE_GEMFILE"] = #{File.expand_path("../../../Gemfile", __dir__).dump}
        exec(
          #{RbConfig.ruby.dump}, #{bundle_executable.dump},
          "exec", #{File.expand_path("../../../bin/hive", __dir__).dump}, *ARGV
        )
      RUBY
      candidate_artifact = Dir.glob(File.join(artifacts, "hive-cli-*.gem")).fetch(0)
      receipts = write_installation_receipts(
        dir,
        candidate_path: candidate,
        candidate_artifact: candidate_artifact,
        openclaw_path: openclaw
      )
      evidence_path = File.join(dir, "evidence.json")
      runner = build_runner(
        artifact_dir: artifacts,
        evidence_path: evidence_path,
        candidate_install_receipt: receipts.fetch("candidate"),
        openclaw_install_receipt: receipts.fetch("openclaw"),
        base_environment: { "PATH" => ENV.fetch("PATH"), "LANG" => "C.UTF-8" }
      )

      evidence = runner.call

      assert_equal "passed", evidence.fetch("result"), evidence.fetch("detail", evidence.inspect)
      assert_equal "proof_passed", evidence.fetch("reason")
      slug = evidence.dig("task", "slug")
      assert_match HiveLiveAgentProof::WORKFLOW_CREATOR_SAFE_SLUG, slug
      assert_equal slug, evidence.dig("task", "first_slug")
      assert_equal slug, evidence.dig("task", "retry_slug")
      assert_equal HiveLiveAgentProof.workflow_creator_commands(slug),
                   evidence.fetch("hive_commands")
      assert_equal(
        "OpenClaw #{HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION} (fixture)",
        evidence.dig("executables", "openclaw", "version")
      )
      assert_equal(
        {
          "version" => HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
          "integrity" => HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY,
          "lock_sha256" => HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_LOCK_SHA256,
          "package_count" =>
            HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_LOCK_PACKAGE_COUNT,
          "receipt_sha256" => Digest::SHA256.file(receipts.fetch("openclaw")).hexdigest,
          "verified" => true
        },
        evidence.fetch("openclaw_package")
      )
      refute_equal evidence.dig("executables", "candidate", "realpath"),
                   evidence.dig("executables", "audit_gateway", "realpath")
      gateway_runtime = evidence.dig(
        "executables", "audit_gateway", "runtime_bundle"
      )
      assert_equal "hive-openclaw-audit-gateway-runtime",
                   gateway_runtime.fetch("schema")
      assert_equal 1, gateway_runtime.fetch("schema_version")
      assert_match(/\A[0-9a-f]{64}\z/, gateway_runtime.fetch("config_sha256"))
      assert_match(/\A[0-9a-f]{64}\z/, gateway_runtime.fetch("manifest_sha256"))
      assert_equal %w[
        attempt_ledger.rb candidate_executor.rb candidate_identity.rb main.rb result_ledger.rb
        task_binding.rb
      ], gateway_runtime.fetch("files").map { |row| row.fetch("name") }.sort
      assert_equal "passed", evidence.dig("teardown", "status")
      assert_equal "passed", evidence.dig("cleanup", "status")
      assert_equal "passed", evidence.dig("secret_scan", "status")
      assert_equal "enforced", evidence.dig("effect_policy", "status")
      assert_equal "observed", evidence.dig("effect_observations", "status")
      assert_equal 2, evidence.dig(
        "effect_observations", "filesystem_observation_count"
      )
      assert_equal 7, evidence.dig("effect_observations", "negative_control_count")
      assert evidence.dig("effect_observations", "network_observations").all? {
        |row| %w[unattributed_agent_window unattributed_process_window].include?(
          row.fetch("classification")
        )
      }
      assert_equal(
        {
          "proof_mode" => "direct_native_tool_surface",
          "model_loop" => "not_exercised",
          "driver_sha256" => Digest::SHA256.file(
            HiveLiveAgentProof::OpenClawCreatorProof::OpenClawPolicyProbe::DRIVER_SOURCE_PATH
          ).hexdigest,
          "receipt_sha256" => evidence.dig(
            "effect_observations", "authoring", "receipt_sha256"
          )
        },
        evidence.dig("effect_observations", "authoring")
      )
      assert_match(
        /\A[0-9a-f]{64}\z/,
        evidence.dig("effect_observations", "authoring", "receipt_sha256")
      )
      assert evidence.fetch("processes").all? {
        |process| process.dig("network", "status") == "observed"
      }
      assert_equal [], evidence.fetch("unauthorized_effects_observed")
      assert_equal [], evidence.fetch("external_actions")
      assert_equal(
        "scoped_policy_and_filesystem_observations",
        evidence.dig("external_actions_scope", "derivation")
      )
      assert_equal "unverified",
                   evidence.dig("external_actions_scope", "network_authorization")
      assert_equal false,
                   evidence.dig("external_actions_scope", "global_effect_absence_claimed")
      refute_includes File.read(evidence_path), CREDENTIAL
    end
  end

  def test_native_policy_and_authoring_use_only_public_openclaw_exports
    wrapper = File.read(
      File.expand_path(
        "../../../packaging/live_agent_skills/openclaw_creator_proof/openclaw_policy_probe.rb",
        __dir__
      )
    )
    driver = File.read(
      File.expand_path(
        "../../../packaging/live_agent_skills/openclaw_native_tools.mjs",
        __dir__
      )
    )
    surface = File.read(
      File.expand_path(
        "../../../packaging/live_agent_skills/openclaw_creator_proof/native_authoring_surface.rb",
        __dir__
      )
    )

    assert_includes driver, "openclaw/plugin-sdk/agent-harness"
    assert_includes driver, "createOpenClawCodingTools"
    assert_includes driver, "openclaw/plugin-sdk/config-schema"
    assert_includes driver, "OpenClawSchema"
    [ wrapper, driver ].each do |source|
      refute_match(/tools-effective-inventory-[A-Za-z0-9_-]+/, source)
      refute_match(/agent-tools-[A-Za-z0-9_-]+/, source)
    end
    assert_includes wrapper, "DRIVER_SOURCE_PATH"
    assert_includes wrapper, "File.lstat(DRIVER_SOURCE_PATH)"
    refute_includes wrapper, "<<~JAVASCRIPT"
    refute_includes surface, "fixture_write"
    refute_includes surface, "fixture_remove_children"
  end

  def test_audit_gateway_installer_keeps_a_verified_committed_runtime_boundary
    source_root = File.expand_path(
      "../../../packaging/live_agent_skills/openclaw_creator_proof",
      __dir__
    )
    installer = File.read(File.join(source_root, "audit_gateway.rb"))
    runtime_files =
      HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway::RUNTIME_FILES

    assert_operator installer.lines.length, :<, 350
    assert_includes installer, "expected_runtime_digests"
    assert_includes installer, "require File.join(runtime_dir"
    refute_includes installer, "eval("
    refute_includes installer, "def current_tree"
    assert_equal %w[
      attempt_ledger.rb candidate_identity.rb candidate_executor.rb result_ledger.rb
      task_binding.rb main.rb
    ], runtime_files
    runtime_files.each do |name|
      path = File.join(source_root, "gateway_runtime", name)
      assert File.file?(path), name
      refute File.symlink?(path), name
      assert_operator File.readlines(path).length, :<, 350, name
    end
    result_reader = File.read(File.join(source_root, "gateway_runtime", "result_ledger.rb"))
    main = File.read(File.join(source_root, "gateway_runtime", "main.rb"))
    task_binding = File.read(File.join(source_root, "gateway_runtime", "task_binding.rb"))
    refute_includes result_reader, "File::APPEND"
    assert_equal 1, main.scan("@result_appender.append").length
    assert_includes task_binding, 'File.join(workspace, ".hive-state")'
    assert_includes task_binding, "File::NOFOLLOW"
  end

  private

  def install_result_binding_gateway(dir, created: true, workflow: "editorial",
                                     task_key: HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_KEY,
                                     result_slug: nil)
    candidate = File.join(dir, "candidate-hive")
    workspace = File.join(dir, "workspace")
    audit = File.join(dir, "audit.jsonl")
    results = File.join(dir, "results.jsonl")
    calls = File.join(dir, "candidate-calls.jsonl")
    run_marker = File.join(dir, "candidate-run")
    slug = "research-and-draft-the-launch-260728-abcd"
    result_slug ||= slug
    meta = File.join(
      workspace, ".hive-state", "stages", "1-research", slug, "meta.yml"
    )
    meta_payload = {
      "slug" => slug,
      "workflow" => workflow,
      "idempotency_key" => task_key
    }
    FileUtils.mkdir_p(workspace)
    write_executable(candidate, <<~RUBY)
      #!#{RbConfig.ruby}
      require "fileutils"
      require "json"
      ordinal = File.file?(#{calls.dump}) ? File.readlines(#{calls.dump}).length + 1 : 1
      File.open(#{calls.dump}, "a", 0o600) { |file| file.puts(JSON.generate(ARGV)) }
      File.write(#{run_marker.dump}, "ran") if ARGV.first == "run"
      case ordinal
      when 4
        puts JSON.generate(
          "schema" => "hive-workflow-validate",
          "valid" => true,
          "stages" => %w[research draft approval].map { |name| { "name" => name } },
          "automatic_edges" => [
            { "from" => "research", "to" => "draft" },
            { "from" => "draft", "to" => "approval" }
          ],
          "human_outcomes" => []
        )
      when 6
        FileUtils.mkdir_p(#{File.dirname(meta).dump})
        File.binwrite(#{meta.dump}, #{YAML.dump(meta_payload).dump})
        puts JSON.generate(
          "schema" => "hive-new",
          "slug" => #{result_slug.dump},
          "created" => #{created.inspect}
        )
      else
        puts ARGV.join(" ")
      end
    RUBY
    gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
      candidate_path: candidate,
      directory: File.join(dir, "gateway"),
      audit_path: audit,
      result_path: results,
      workspace: workspace
    ).install
    {
      gateway: gateway,
      workspace: workspace,
      audit: audit,
      results: results,
      calls: calls,
      run_marker: run_marker,
      slug: slug
    }
  end

  def drive_gateway_prefix(fixture, count:)
    commands = HiveLiveAgentProof.workflow_creator_commands(fixture.fetch(:slug)).first(count)
    commands.each do |argv|
      _stdout, stderr, status = Open3.capture3(fixture.fetch(:gateway), *argv)
      assert status.success?, "#{argv.inspect}: #{stderr}"
    end
  end

  def rewrite_result_rows(path)
    rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
    File.write(path, "#{yield(rows).map { |row| JSON.generate(row) }.join("\n")}\n")
  end

  def assert_worker_loss_is_bounded(signal)
    with_tmp_dir do |dir|
      script = File.join(dir, "worker-loss")
      ready = File.join(dir, "worker-loss-ready")
      target_pid_path = File.join(dir, "worker-loss-target-pid")
      descendant_pid_path = File.join(dir, "worker-loss-descendant-pid")
      descendant_source = <<~RUBY
        Process.setsid
        second = fork do
          trap("TERM", "IGNORE")
          File.write(#{descendant_pid_path.dump}, Process.pid.to_s)
          loop { sleep 1 }
        end
        Process.detach(second)
        exit! 0
      RUBY
      write_executable(script, <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{target_pid_path.dump}, Process.pid.to_s)
        first = spawn(
          #{RbConfig.ruby.dump}, "-e", #{descendant_source.dump},
          out: File::NULL, err: File::NULL
        )
        Process.wait(first)
        sleep 0.01 until File.file?(#{descendant_pid_path.dump})
        File.write(#{ready.dump}, "ready")
        loop { sleep 1 }
      RUBY
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 0.3,
        term_grace: 0.05,
        output_limit: 64,
        exact_secrets: []
      )
      execution = Thread.new do
        runner.call(environment: {}, argv: [ script ], chdir: dir)
      end
      execution.report_on_exception = false

      Timeout.timeout(2) do
        sleep 0.01 until File.file?(ready) && runner.worker_pid
      end
      worker_pid = runner.worker_pid
      target_pid = Integer(File.read(target_pid_path), 10)
      descendant_pid = Integer(File.read(descendant_pid_path), 10)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill(signal, worker_pid)

      error = Timeout.timeout(6) do
        assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
          execution.value
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal "containment_failed", error.reason
      assert_operator elapsed, :<, 6
      [ worker_pid, target_pid, descendant_pid ].each do |pid|
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      end
    ensure
      if execution&.alive?
        execution.kill
        execution.join(5)
      end
    end
  end

  def build_runner(candidate_sha: SHA, artifact_dir: "/proof/artifacts",
                   evidence_path: File.join(Dir.tmpdir, "unused-openclaw-proof-evidence.json"),
                   model: "openai/gpt-5.6", base_environment: {},
                   candidate_install_receipt: "/proof/candidate-installation-receipt.json",
                   openclaw_install_receipt: "/proof/openclaw-installation-receipt.json",
                   **options)
    HiveLiveAgentProof::OpenClawCreatorProof::Runner.new(
      candidate_sha: candidate_sha,
      artifact_dir: artifact_dir,
      evidence_path: evidence_path,
      model: model,
      provider_credential: CREDENTIAL,
      candidate_install_receipt: candidate_install_receipt,
      openclaw_install_receipt: openclaw_install_receipt,
      base_environment: base_environment,
      **options
    )
  end

  def write_installation_receipts(dir, candidate_path:, candidate_artifact:,
                                  openclaw_path:)
    candidate_root = File.dirname(candidate_path)
    openclaw_root = File.dirname(openclaw_path)
    lock_path = File.join(openclaw_root, "package-lock.json")
    FileUtils.chmod(0o700, candidate_root) if File.directory?(candidate_root)
    FileUtils.chmod(0o700, openclaw_root) if File.directory?(openclaw_root)
    FileUtils.chmod(0o600, lock_path) if File.file?(lock_path)
    FileUtils.cp(
      HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_LOCK_PATH,
      lock_path
    )
    candidate_receipt = File.join(dir, "candidate-installation-receipt.json")
    openclaw_receipt = File.join(dir, "openclaw-installation-receipt.json")
    HiveLiveAgentProof::OpenClawCreatorProof::InstallationReceipt.write(
      path: candidate_receipt,
      kind: "candidate_gem",
      artifact_path: candidate_artifact,
      install_root: candidate_root,
      executable_path: candidate_path,
      package_name: "hive-cli",
      package_version: Hive::VERSION
    )
    HiveLiveAgentProof::OpenClawCreatorProof::InstallationReceipt.write(
      path: openclaw_receipt,
      kind: "openclaw_npm",
      artifact_path: lock_path,
      install_root: openclaw_root,
      executable_path: openclaw_path,
      package_name: "openclaw",
      package_version: HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
      package_integrity: HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY,
      lock_path: lock_path,
      package_count:
        HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_LOCK_PACKAGE_COUNT,
      interpreter_path: node_executable
    )
    { "candidate" => candidate_receipt, "openclaw" => openclaw_receipt }
  end

  def prepare_candidate_artifacts(dir)
    artifacts = File.join(dir, "candidate-artifacts")
    gem = File.join(dir, "hive-cli-#{Hive::VERSION}.gem")
    source = File.join(dir, "source.tar.gz")
    File.write(gem, "candidate gem bytes")
    File.write(source, "candidate source bytes")
    HiveLiveAgentProof::Builder.new(
      candidate_sha: SHA,
      gem_path: gem,
      source_archive: source,
      output_dir: artifacts,
      canonical: Hive::AgentSkills::CanonicalSkill.new
    ).call
    artifacts
  end

  def write_fake_openclaw(path)
    write_fake_openclaw_public_exports(File.dirname(path))
    write_executable(path, <<~JAVASCRIPT)
      #!/usr/bin/env node
      const fs = require("fs");
      const path = require("path");
      const { spawnSync } = require("child_process");
      const argv = process.argv.slice(2);
      const abort = (message) => { console.error(message); process.exit(1); };
      const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);

      if (same(argv, ["--version"])) {
        console.log(
          "OpenClaw #{HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION} (fixture)"
        );
        process.exit(0);
      }

      const config = JSON.parse(fs.readFileSync(process.env.OPENCLAW_CONFIG_PATH, "utf8"));
      const workspace = config.agents.defaults.workspace;
      const prepended = config.tools.exec.pathPrepend;
      if (!Array.isArray(prepended) || prepended.length !== 1) abort("missing native pathPrepend");
      const model = config.agents.defaults.model.primary;
      const credentialName = model.startsWith("openrouter/") ?
        "OPENROUTER_API_KEY" : "OPENAI_API_KEY";
      const oppositeName = credentialName === "OPENAI_API_KEY" ?
        "OPENROUTER_API_KEY" : "OPENAI_API_KEY";
      if (!process.env[credentialName]) abort("selected provider credential missing");
      if (Object.hasOwn(process.env, oppositeName)) abort("opposite credential reached OpenClaw");
      if (Object.hasOwn(process.env, "HIVE_LIVE_PROVIDER_CREDENTIAL")) {
        abort("generic credential reached OpenClaw");
      }
      if (Object.hasOwn(process.env, "HIVE_CANDIDATE_INSTALL_RECEIPT")) {
        abort("candidate receipt reached OpenClaw");
      }
      if (Object.hasOwn(process.env, "HIVE_OPENCLAW_INSTALL_RECEIPT")) {
        abort("OpenClaw receipt reached OpenClaw");
      }
      const approvals = JSON.parse(
        fs.readFileSync(path.join(process.env.OPENCLAW_STATE_DIR, "exec-approvals.json"), "utf8")
      );
      const gateway = path.join(prepended[0], "hive");
      const allowed = approvals.agents.main.allowlist.map((row) => row.pattern);
      if (!same(config.tools.allow, ["read", "write", "edit", "apply_patch", "exec"]) ||
          config.tools.fs.workspaceOnly !== true ||
          config.tools.elevated.enabled !== false ||
          config.tools.exec.applyPatch.enabled !== true ||
          config.tools.exec.applyPatch.workspaceOnly !== true ||
          config.tools.exec.mode !== "allowlist" ||
          approvals.defaults.security !== "deny" ||
          approvals.agents.main.security !== "allowlist" ||
          !same(allowed, [gateway])) {
        abort("OpenClaw tool policy is not deny-by-default");
      }

      if (same(argv, ["skills", "info", "hive", "--json"])) {
        console.log(JSON.stringify({
          name: "hive",
          eligible: true,
          userInvocable: true,
          filePath: path.join(workspace, "skills", "hive", "SKILL.md")
        }));
        process.exit(0);
      }

      const messageIndex = argv.indexOf("--message");
      if (!argv.includes("agent") || messageIndex < 0) abort("unsupported fake OpenClaw argv");
      const message = argv[messageIndex + 1];
      const commandEnvironment = {
        ...process.env,
        PATH: [...prepended, process.env.PATH].join(path.delimiter)
      };
      const run = (...command) => {
        const result = spawnSync(gateway, command, {
          cwd: workspace, env: commandEnvironment, encoding: "utf8"
        });
        if (result.status !== 0) abort(`hive ${command.join(" ")} failed: ${result.stderr}`);
        return result.stdout;
      };

      if (message.includes(#{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_KEY.dump})) {
        const taskArgv = #{JSON.generate(HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_NEW_ARGV)};
        const first = JSON.parse(run(...taskArgv));
        run("run", first.slug);
        const retryResult = JSON.parse(run(...taskArgv));
        if (retryResult.slug !== first.slug || retryResult.created !== false) {
          abort("idempotent retry changed slug");
        }
        run("status", "--operational", "--json");
      } else {
        run("workflow", "list", "--json");
        const scaffold = JSON.parse(run("workflow", "new", "editorial", "--json"));
        const nativeResult = spawnSync(
          process.env.HIVE_OPENCLAW_NATIVE_TOOL_NODE,
          [
            process.env.HIVE_OPENCLAW_NATIVE_TOOL_DRIVER,
            "author-workflow",
            process.env.HIVE_OPENCLAW_NATIVE_TOOL_INSTALL_ROOT,
            process.env.HIVE_OPENCLAW_NATIVE_TOOL_CONFIG,
            process.env.HIVE_OPENCLAW_NATIVE_TOOL_APPROVALS,
            process.env.HIVE_OPENCLAW_NATIVE_TOOL_WORKSPACE,
            process.env.HIVE_OPENCLAW_NATIVE_TOOL_AUTHORING_RECEIPT,
            process.env.HIVE_OPENCLAW_NATIVE_TOOL_EXPECTED_VERSION,
            scaffold.descriptor_path,
            path.dirname(scaffold.instruction_path)
          ],
          { cwd: workspace, env: process.env, encoding: "utf8" }
        );
        if (nativeResult.status !== 0 ||
            JSON.parse(nativeResult.stdout).schema !== "hive-openclaw-native-authoring") {
          abort(`native OpenClaw authoring failed: ${nativeResult.stderr}`);
        }
        run("workflow", "validate", "editorial", "--json");
        run("workflow", "commit", "editorial");
      }
      console.log(JSON.stringify({ ok: true }));
    JAVASCRIPT
  end

  def write_fake_openclaw_public_exports(root)
    fixture = File.expand_path(
      "../../fixtures/openclaw_public_export_contract",
      __dir__
    )
    package_root = File.join(root, "node_modules", "openclaw")
    FileUtils.mkdir_p(File.dirname(package_root))
    FileUtils.cp_r(fixture, package_root)
    File.write(
      File.join(root, "package.json"),
      JSON.generate("name" => "hive-openclaw-proof-fixture", "private" => true)
    )
  end

  def node_executable
    executable = ENV.fetch("PATH").split(File::PATH_SEPARATOR).filter_map do |directory|
      candidate = File.join(directory, "node")
      File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end.first
    raise "node executable is unavailable" unless executable

    executable
  end

  def write_archive(path, *entries)
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        entries.each do |kind, name, content|
          case kind
          when :directory
            tar.mkdir(name, 0o700)
          when :file
            tar.add_file_simple(name, 0o600, content.bytesize) { |io| io.write(content) }
          when :symlink
            tar.add_symlink(name, content, 0o700)
          else
            raise "unsupported test archive entry #{kind}"
          end
        end
      end
    end
  end

  def write_raw_archive(path, name:, typeflag:, linkname:)
    header = Gem::Package::TarHeader.new(
      name: name,
      size: 0,
      prefix: "",
      mode: 0o600,
      typeflag: typeflag,
      linkname: linkname
    )
    Zlib::GzipWriter.open(path) do |gzip|
      gzip.write(header.to_s)
      gzip.write("\0" * 1_024)
    end
  end

  def audit_rows(path)
    File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
  end

  def terminal_audit_rows(path)
    audit_rows(path).select { |row| row.fetch("phase") == "terminal" }
  end

  def assert_attempt_pairs(rows, expected_decisions:)
    pairs = rows.each_slice(2).to_a
    assert_equal expected_decisions.length, pairs.length
    pairs.each_with_index do |pair, index|
      assert_equal 2, pair.length
      attempted, terminal = pair
      assert_equal "hive-openclaw-command-attempt", attempted.fetch("schema")
      assert_equal 2, attempted.fetch("schema_version")
      assert_equal "attempted", attempted.fetch("phase")
      assert_equal "terminal", terminal.fetch("phase")
      assert_equal index + 1, attempted.fetch("ordinal")
      assert_equal attempted.fetch("ordinal"), terminal.fetch("ordinal")
      assert_equal attempted.fetch("attempt_id"), terminal.fetch("attempt_id")
      assert_equal attempted.fetch("argv"), terminal.fetch("argv")
      assert_equal expected_decisions.fetch(index), terminal.fetch("decision")
      assert_match(/\A[0-9a-f]{64}\z/, attempted.fetch("attempt_id"))
    end
  end

  def write_executable(path, content)
    File.write(path, content, mode: "w", perm: 0o700)
    FileUtils.chmod(0o700, path)
  end
end
