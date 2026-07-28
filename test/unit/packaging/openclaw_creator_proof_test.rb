require "test_helper"
require "json"
require "rbconfig"
require "rubygems/package"
require "zlib"
require_relative "../../../packaging/live_agent_skills/openclaw_creator_proof"

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
        proven_hive_bin: "/proof/hive",
        openclaw_bin: "/proof/openclaw",
        base_environment: {}
      )

      evidence = runner.call

      assert_equal "missing_provider_credential", evidence.fetch("reason")
      assert_equal "OPENROUTER_API_KEY", evidence.dig("provider", "credential_environment")
    end
  end

  def test_openclaw_package_metadata_must_match_the_pinned_identity
    variants = [
      [ "missing-version", "", HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY,
        "missing_openclaw_package_version" ],
      [ "wrong-version", "2026.7.2", HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY,
        "openclaw_package_version_mismatch" ],
      [ "missing-integrity", HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION, "",
        "missing_openclaw_package_integrity" ],
      [ "wrong-integrity", HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
        "sha512-not-the-pinned-package", "openclaw_package_integrity_mismatch" ]
    ]

    with_tmp_dir do |dir|
      variants.each do |name, version, integrity, reason|
        evidence = build_runner(
          evidence_path: File.join(dir, "#{name}.json"),
          openclaw_package_version: version,
          openclaw_package_integrity: integrity
        ).call

        assert_equal "preflight", evidence.fetch("phase")
        assert_equal reason, evidence.fetch("reason")
        assert_equal(
          {
            "version" => HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
            "integrity" => HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY,
            "verified" => false
          },
          evidence.fetch("openclaw_package")
        )
      end
    end
  end

  def test_from_env_consumes_only_verified_openclaw_package_metadata
    with_tmp_dir do |dir|
      evidence = HiveLiveAgentProof::OpenClawCreatorProof::Runner.from_env(
        "HIVE_CANDIDATE_SHA" => SHA,
        "HIVE_PROOF_ARTIFACTS" => File.join(dir, "missing-artifacts"),
        "HIVE_CREATOR_EVIDENCE_PATH" => File.join(dir, "evidence.json"),
        "HIVE_LIVE_MODEL" => "openai/gpt-5.6",
        "HIVE_LIVE_PROVIDER_CREDENTIAL" => CREDENTIAL,
        "HIVE_PROVEN_HIVE_BIN" => File.join(dir, "missing-hive"),
        "HIVE_OPENCLAW_BIN" => File.join(dir, "missing-openclaw"),
        "HIVE_OPENCLAW_PACKAGE_VERSION" =>
          HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
        "HIVE_OPENCLAW_PACKAGE_INTEGRITY" =>
          HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY
      ).call

      assert_equal "candidate_not_executable", evidence.fetch("reason")
      assert_equal true, evidence.dig("openclaw_package", "verified")
    end
  end

  def test_missing_candidate_binary_is_reported_before_artifact_work
    with_tmp_dir do |dir|
      openclaw = File.join(dir, "openclaw")
      write_executable(openclaw, "#!#{RbConfig.ruby}\n")
      evidence = build_runner(
        evidence_path: File.join(dir, "evidence.json"),
        proven_hive_bin: File.join(dir, "missing-hive"),
        openclaw_bin: openclaw
      ).call

      assert_equal "candidate_not_executable", evidence.fetch("reason")
      assert_nil evidence.dig("executables", "candidate", "sha256")
    end
  end

  def test_missing_artifact_directory_is_typed_after_executable_identity
    with_tmp_dir do |dir|
      candidate = File.join(dir, "hive")
      openclaw = File.join(dir, "openclaw")
      write_executable(candidate, "#!#{RbConfig.ruby}\n")
      write_executable(openclaw, "#!#{RbConfig.ruby}\n")
      evidence = build_runner(
        artifact_dir: File.join(dir, "missing-artifacts"),
        evidence_path: File.join(dir, "evidence.json"),
        proven_hive_bin: candidate,
        openclaw_bin: openclaw
      ).call

      assert_equal "artifact_directory_missing", evidence.fetch("reason")
      assert_match(/\A[0-9a-f]{64}\z/, evidence.dig("executables", "candidate", "sha256"))
      assert_match(/\A[0-9a-f]{64}\z/, evidence.dig("executables", "openclaw", "sha256"))
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
      configuration =
        HiveLiveAgentProof::OpenClawCreatorProof::OpenClawConfiguration.new(
          root: dir,
          workspace: workspace,
          model: "openrouter/openai/gpt-5.6",
          gateway_bin_dir: gateway_bin
        )

      payload = configuration.write

      assert_equal [ gateway_bin ], payload.dig("tools", "exec", "pathPrepend")
      assert_equal "coding", payload.dig("tools", "profile")
      assert_equal workspace, payload.dig("agents", "defaults", "workspace")
      assert_equal "openrouter/openai/gpt-5.6",
                   payload.dig("agents", "defaults", "model", "primary")
      assert_equal payload, JSON.parse(File.read(configuration.config_path))
    end
  end

  def test_audit_gateway_binds_real_candidate_digest_and_exact_command_order
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      calls = File.join(dir, "candidate-calls.jsonl")
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
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

      first_out, first_err, first_status = Open3.capture3(gateway, "version")
      second_out, second_err, second_status = Open3.capture3(
        gateway, "workflow", "list", "--json"
      )

      assert first_status.success?, first_err
      assert second_status.success?, second_err
      assert_equal "candidate:version\n", first_out
      assert_equal "candidate:workflow list --json\n", second_out
      assert_equal(
        HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.first(2),
        File.readlines(audit, chomp: true).map { |line| JSON.parse(line).fetch("argv") }
      )
      assert_equal(
        HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.first(2),
        File.readlines(calls, chomp: true).map { |line| JSON.parse(line) }
      )
      refute_equal File.realpath(candidate), File.realpath(gateway)
    end
  end

  def test_audit_gateway_rejects_wrong_order_before_audit_and_candidate_exec
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

      assert_equal 64, status.exitstatus
      assert_includes stderr, "expected [\"version\"]"
      refute File.exist?(audit)
      refute File.exist?(marker)
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
      refute File.exist?(audit)
    end
  end

  def test_audit_gateway_binds_dynamic_run_to_the_idempotent_created_slug
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate-hive")
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        puts ARGV.join(" ")
      RUBY
      workspace = File.join(dir, "workspace")
      slug = "research-and-draft-the-launch-260728-abcd"
      meta = File.join(workspace, ".hive-state", "stages", "1-research", slug, "meta.yml")
      FileUtils.mkdir_p(File.dirname(meta))
      File.write(
        meta,
        YAML.dump(
          "slug" => slug,
          "workflow" => "editorial",
          "idempotency_key" => HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_KEY
        )
      )
      commands = [
        [ "new" ],
        [ "run", HiveLiveAgentProof::WORKFLOW_CREATOR_RUN_PLACEHOLDER ],
        [ "new" ]
      ]
      audit = File.join(dir, "audit.jsonl")
      gateway = HiveLiveAgentProof::OpenClawCreatorProof::AuditGateway.new(
        candidate_path: candidate,
        directory: File.join(dir, "gateway"),
        audit_path: audit,
        commands: commands,
        workspace: workspace
      ).install

      _first_out, first_err, first_status = Open3.capture3(gateway, "new")
      _wrong_out, wrong_err, wrong_status = Open3.capture3(gateway, "run", "invented-slug")
      run_out, run_err, run_status = Open3.capture3(gateway, "run", slug)
      _retry_out, retry_err, retry_status = Open3.capture3(gateway, "new")
      rows = File.readlines(audit, chomp: true).map { |line| JSON.parse(line) }

      assert first_status.success?, first_err
      assert_equal 64, wrong_status.exitstatus
      assert_includes wrong_err, "expected [\"run\", \"#{slug}\"]"
      assert run_status.success?, run_err
      assert_equal "run #{slug}\n", run_out
      assert retry_status.success?, retry_err
      assert_equal [ [ "new" ], [ "run", slug ], [ "new" ] ],
                   rows.map { |row| row.fetch("argv") }
      assert_nil rows.fetch(0).fetch("dynamic_slug")
      assert_equal slug, rows.fetch(1).fetch("dynamic_slug")
      assert_nil rows.fetch(2).fetch("dynamic_slug")
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
        timeout: 0.05,
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

  def test_process_runner_escalates_to_kill_when_term_is_ignored
    with_tmp_dir do |dir|
      script = File.join(dir, "ignore-term")
      write_executable(script, <<~RUBY)
        #!#{RbConfig.ruby}
        trap("TERM", "IGNORE")
        loop { sleep 1 }
      RUBY
      runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
        timeout: 0.05,
        term_grace: 0.05,
        output_limit: 64,
        exact_secrets: []
      )

      result = runner.call(environment: {}, argv: [ script ], chdir: dir)

      assert_equal true, result.dig("record", "timed_out")
      assert_equal true, result.dig("record", "teardown", "term_sent")
      assert_equal true, result.dig("record", "teardown", "kill_sent")
      assert_equal true, result.dig("record", "teardown", "reaped")
      assert_equal "none", result.dig("record", "teardown", "descendants")
    end
  end

  def test_process_runner_cleans_a_descendant_left_by_a_successful_parent
    with_tmp_dir do |dir|
      script = File.join(dir, "descendant")
      ready = File.join(dir, "descendant-ready")
      descendant_source =
        "trap('TERM', 'IGNORE'); File.write(#{ready.dump}, 'ready'); loop { sleep 1 }"
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

  def test_cleanup_failure_overrides_an_ordinary_failure_and_remains_typed
    with_tmp_dir do |dir|
      candidate = File.join(dir, "hive")
      openclaw = File.join(dir, "openclaw")
      artifacts = File.join(dir, "artifacts")
      root = File.join(dir, "proof-root")
      FileUtils.mkdir_p([ artifacts, root ])
      write_executable(candidate, "#!#{RbConfig.ruby}\n")
      write_executable(openclaw, "#!#{RbConfig.ruby}\n")
      runner = build_runner(
        artifact_dir: artifacts,
        evidence_path: File.join(dir, "evidence.json"),
        proven_hive_bin: candidate,
        openclaw_bin: openclaw,
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
      openclaw = File.join(dir, "openclaw")
      candidate = File.join(dir, "candidate-hive")
      write_fake_openclaw(openclaw)
      write_executable(candidate, <<~RUBY)
        #!#{RbConfig.ruby}
        ENV["GEM_HOME"] = #{Gem.dir.dump}
        ENV["GEM_PATH"] = #{Gem.path.join(File::PATH_SEPARATOR).dump}
        ENV["BUNDLE_GEMFILE"] = #{File.expand_path("../../../Gemfile", __dir__).dump}
        exec(
          "/home/asterio/.local/share/gem/ruby/3.4.0/bin/bundle",
          "exec", #{File.expand_path("../../../bin/hive", __dir__).dump}, *ARGV
        )
      RUBY
      evidence_path = File.join(dir, "evidence.json")
      runner = build_runner(
        artifact_dir: artifacts,
        evidence_path: evidence_path,
        proven_hive_bin: candidate,
        openclaw_bin: openclaw,
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
          "verified" => true
        },
        evidence.fetch("openclaw_package")
      )
      refute_equal evidence.dig("executables", "candidate", "realpath"),
                   evidence.dig("executables", "audit_gateway", "realpath")
      assert_equal "passed", evidence.dig("teardown", "status")
      assert_equal "passed", evidence.dig("cleanup", "status")
      assert_equal "passed", evidence.dig("secret_scan", "status")
      refute_includes File.read(evidence_path), CREDENTIAL
    end
  end

  private

  def build_runner(candidate_sha: SHA, artifact_dir: "/proof/artifacts",
                   evidence_path: File.join(Dir.tmpdir, "unused-openclaw-proof-evidence.json"),
                   model: "openai/gpt-5.6", base_environment: {},
                   proven_hive_bin: "/proof/hive", openclaw_bin: "/proof/openclaw",
                   openclaw_package_version:
                     HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION,
                   openclaw_package_integrity:
                     HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_INTEGRITY,
                   **options)
    HiveLiveAgentProof::OpenClawCreatorProof::Runner.new(
      candidate_sha: candidate_sha,
      artifact_dir: artifact_dir,
      evidence_path: evidence_path,
      model: model,
      provider_credential: CREDENTIAL,
      proven_hive_bin: proven_hive_bin,
      openclaw_bin: openclaw_bin,
      openclaw_package_version: openclaw_package_version,
      openclaw_package_integrity: openclaw_package_integrity,
      base_environment: base_environment,
      **options
    )
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
    write_executable(path, <<~RUBY)
      #!#{RbConfig.ruby}
      require "fileutils"
      require "json"
      require "open3"

      if ARGV == ["--version"]
        puts "OpenClaw #{HiveLiveAgentProof::OpenClawCreatorProof::OPENCLAW_VERSION} (fixture)"
        exit 0
      end

      config = JSON.parse(File.read(ENV.fetch("OPENCLAW_CONFIG_PATH")))
      workspace = config.dig("agents", "defaults", "workspace")
      prepended = config.dig("tools", "exec", "pathPrepend")
      abort "missing native pathPrepend" unless prepended.is_a?(Array) && prepended.length == 1
      model = config.dig("agents", "defaults", "model", "primary")
      credential_name = model.start_with?("openrouter/") ? "OPENROUTER_API_KEY" : "OPENAI_API_KEY"
      opposite_name = credential_name == "OPENAI_API_KEY" ? "OPENROUTER_API_KEY" : "OPENAI_API_KEY"
      abort "selected provider credential missing" if ENV.fetch(credential_name, "").empty?
      abort "opposite credential reached OpenClaw" if ENV.key?(opposite_name)
      abort "generic credential reached OpenClaw" if ENV.key?("HIVE_LIVE_PROVIDER_CREDENTIAL")

      if ARGV == ["skills", "info", "hive", "--json"]
        puts JSON.generate(
          "name" => "hive",
          "eligible" => true,
          "userInvocable" => true,
          "filePath" => File.join(workspace, "skills", "hive", "SKILL.md")
        )
        exit 0
      end

      message_index = ARGV.index("--message")
      abort "unsupported fake OpenClaw argv" unless ARGV.include?("agent") && message_index
      message = ARGV.fetch(message_index + 1)
      command_environment = ENV.to_h.merge(
        "PATH" => [*prepended, ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
      )
      run = lambda do |*command|
        stdout, stderr, status = Open3.capture3(
          command_environment, "hive", *command, chdir: workspace
        )
        abort "hive \#{command.join(' ')} failed: \#{stderr}" unless status.success?
        stdout
      end

      if message.include?(#{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_KEY.dump})
        first = JSON.parse(run.call(*#{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_NEW_ARGV.inspect}))
        run.call("run", first.fetch("slug"))
        retry_result = JSON.parse(
          run.call(*#{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_NEW_ARGV.inspect})
        )
        abort "idempotent retry changed slug" unless
          retry_result["slug"] == first["slug"] && retry_result["created"] == false
        run.call("status", "--operational", "--json")
      else
        run.call("version")
        run.call("workflow", "list", "--json")
        scaffold = JSON.parse(run.call("workflow", "new", "editorial", "--json"))
        descriptor = scaffold.fetch("descriptor_path")
        instruction_dir = File.dirname(scaffold.fetch("instruction_path"))
        Dir.children(instruction_dir).each do |name|
          FileUtils.rm_rf(File.join(instruction_dir, name))
        end
        File.write(File.join(instruction_dir, "research.md"), "Research the launch.\\n")
        File.write(File.join(instruction_dir, "draft.md"), "Draft from research.md.\\n")
        File.write(descriptor, <<~YAML)
          id: editorial
          stages:
            - name: research
              kind: agent
              agent: codex
              state_file: research.md
              instruction: editorial/research.md
              permissions: yolo
            - name: draft
              kind: agent
              agent: codex
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
        run.call("workflow", "validate", "editorial", "--json")
        run.call("workflow", "commit", "editorial")
      end
      puts JSON.generate("ok" => true)
    RUBY
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

  def write_executable(path, content)
    File.write(path, content, mode: "w", perm: 0o700)
    FileUtils.chmod(0o700, path)
  end
end
