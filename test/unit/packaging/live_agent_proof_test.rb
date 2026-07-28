require "test_helper"
require "hive/agent_skills/canonical_skill"
require_relative "../../../packaging/live_agent_skills/proof"

class LiveAgentProofTest < Minitest::Test
  include HiveTestHelper

  SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  REPOSITORY = "ivankuznetsov/hive"

  def test_builder_produces_deterministic_four_platform_artifacts
    with_tmp_dir do |dir|
      gem = write_file(File.join(dir, "hive-cli-1.2.3.gem"), "gem-bytes")
      source = write_file(File.join(dir, "source.tar.gz"), "source-bytes")
      first = File.join(dir, "first")
      second = File.join(dir, "second")
      canonical = Hive::AgentSkills::CanonicalSkill.new

      one = build(gem, source, first, canonical)
      two = build(gem, source, second, canonical)

      assert_equal one, two
      assert_equal canonical.canonical_digest, one.fetch("canonical_digest")
      assert_equal canonical.version, one.fetch("skill_version")
      skill_name = "hive-agent-skills-#{SHA}.tar.gz"
      assert_equal HiveLiveAgentProof.sha256(File.join(first, skill_name)),
                   HiveLiveAgentProof.sha256(File.join(second, skill_name))

      listing, status = Open3.capture2("tar", "-tzf", File.join(first, skill_name))
      assert status.success?
      %w[openclaw claude codex pi].each do |platform|
        assert_includes listing, "./#{platform}/hive/SKILL.md"
        assert_includes listing, "./#{platform}/hive/.hive-skill.json"
      end
      assert_includes listing, "./codex/hive/agents/openai.yaml"

      error = assert_raises(HiveLiveAgentProof::Error) do
        build(gem, source, first, canonical)
      end
      assert_includes error.message, "must be empty"
    end
  end

  def test_candidate_verifier_accepts_exact_offline_artifacts_and_four_projections
    with_tmp_dir do |dir|
      canonical = Hive::AgentSkills::CanonicalSkill.new
      artifacts = prepare_release_artifacts(dir, canonical)

      verified = verify_candidate(artifacts, canonical)

      assert_equal File.join(artifacts, "hive-cli-#{Hive::VERSION}.gem"), verified.fetch("gem")
      assert_equal File.join(artifacts, "hive-agent-skills-#{SHA}.tar.gz"), verified.fetch("skills")
      assert_equal File.join(artifacts, "hive-source-#{SHA}.tar.gz"), verified.fetch("source")
      assert_equal HiveLiveAgentProof::PLATFORMS, verified.fetch("platforms")
    end
  end

  def test_candidate_verifier_rejects_manifest_and_projection_substitution
    with_tmp_dir do |dir|
      canonical = Hive::AgentSkills::CanonicalSkill.new
      artifacts = prepare_release_artifacts(dir, canonical)
      manifest_path = File.join(artifacts, "artifact-manifest.json")
      manifest = JSON.parse(File.read(manifest_path))
      manifest["hive_version"] = "0.0.0"
      HiveLiveAgentProof.write_json(manifest_path, manifest)

      error = assert_raises(HiveLiveAgentProof::Error) { verify_candidate(artifacts, canonical) }
      assert_includes error.message, "Hive version"

      artifacts = prepare_release_artifacts(File.join(dir, "projection"), canonical)
      skill_path = File.join(artifacts, "hive-agent-skills-#{SHA}.tar.gz")
      stage = File.join(dir, "stage")
      FileUtils.mkdir_p(stage)
      assert system("tar", "-xzf", skill_path, "-C", stage)
      File.open(File.join(stage, "codex/hive/SKILL.md"), "a") { |file| file.write("\nsubstitution\n") }
      assert system("tar", "-czf", skill_path, "-C", stage, ".")
      manifest = JSON.parse(File.read(File.join(artifacts, "artifact-manifest.json")))
      record = manifest.fetch("files").fetch(File.basename(skill_path))
      record["sha256"] = HiveLiveAgentProof.sha256(skill_path)
      record["size"] = File.size(skill_path)
      HiveLiveAgentProof.write_json(File.join(artifacts, "artifact-manifest.json"), manifest)

      error = assert_raises(HiveLiveAgentProof::Error) { verify_candidate(artifacts, canonical) }
      assert_includes error.message, "projection"
    end
  end

  def test_candidate_verifier_rejects_per_file_and_total_archive_limits_before_materialization
    with_tmp_dir do |dir|
      canonical = Hive::AgentSkills::CanonicalSkill.new
      oversized_artifacts = prepare_release_artifacts(
        File.join(dir, "oversized"), canonical
      )
      oversized_path =
        File.join(oversized_artifacts, "hive-agent-skills-#{SHA}.tar.gz")
      write_declared_size_archive(
        oversized_path,
        name: "openclaw/hive/SKILL.md",
        size: HiveLiveAgentProof::SKILL_ARCHIVE_FILE_LIMIT + 1
      )
      refresh_artifact_record(oversized_artifacts, oversized_path)

      error = assert_raises(HiveLiveAgentProof::Error) do
        verify_candidate(oversized_artifacts, canonical)
      end
      assert_includes error.message, "entry exceeds"

      cumulative_artifacts = prepare_release_artifacts(
        File.join(dir, "cumulative"), canonical
      )
      cumulative_path =
        File.join(cumulative_artifacts, "hive-agent-skills-#{SHA}.tar.gz")
      write_test_archive(
        cumulative_path,
        "openclaw/hive/SKILL.md" => "a" * 16,
        "claude/hive/SKILL.md" => "b" * 16
      )
      refresh_artifact_record(cumulative_artifacts, cumulative_path)

      error = assert_raises(HiveLiveAgentProof::Error) do
        verify_candidate(
          cumulative_artifacts, canonical,
          archive_file_limit: 20, archive_total_limit: 24
        )
      end
      assert_includes error.message, "expands beyond"
    end
  end

  def test_candidate_verifier_applies_entry_directory_depth_and_inode_budgets
    cases = {
      "entries" => {
        files: { "one" => "", "two" => "" },
        options: { archive_entry_limit: 1 },
        message: "more than 1 entries"
      },
      "directories" => {
        files: { "one/two/file" => "" },
        options: { archive_directory_limit: 1 },
        message: "more than 1 directories"
      },
      "depth" => {
        files: { "one/two/file" => "" },
        options: { archive_depth_limit: 2 },
        message: "exceeds depth 2"
      },
      "inodes" => {
        files: { "one/file" => "" },
        options: { archive_inode_limit: 1 },
        message: "more than 1 inodes"
      }
    }

    with_tmp_dir do |dir|
      canonical = Hive::AgentSkills::CanonicalSkill.new
      cases.each do |name, definition|
        artifacts = prepare_release_artifacts(File.join(dir, name), canonical)
        skill_path = File.join(artifacts, "hive-agent-skills-#{SHA}.tar.gz")
        write_test_archive(skill_path, definition.fetch(:files))
        refresh_artifact_record(artifacts, skill_path)

        error = assert_raises(HiveLiveAgentProof::Error) do
          verify_candidate(artifacts, canonical, **definition.fetch(:options))
        end
        assert_includes error.message, definition.fetch(:message)
      end
    end
  end

  def test_attestor_and_verifier_accept_only_exact_proven_artifacts
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      proof = File.join(dir, "proof")
      result = attest(artifacts, evidence, creator_evidence, proof)

      verified = HiveLiveAgentProof::Verifier.new(
        proof_dir: proof, candidate_sha: SHA, workflow_revision: WORKFLOW_SHA,
        repository: REPOSITORY, run_id: "42", run_attempt: "1", attestation_sha256: result.fetch("sha256")
      ).call

      attestation = result.fetch("attestation")
      assert_equal(
        [ "hive-live-agent-skills-attestation", 1, SHA ],
        attestation.values_at("schema", "schema_version", "candidate_sha")
      )
      assert_equal(
        {
          "path" => ".github/workflows/live-agent-skills.yml",
          "revision" => WORKFLOW_SHA,
          "event" => "workflow_dispatch",
          "repository" => REPOSITORY,
          "run_id" => 42,
          "run_attempt" => 1
        },
        attestation.fetch("workflow")
      )
      creator = attestation.fetch("workflow_creator")
      assert_equal(
        [ "hive-live-workflow-creator-evidence", 1, "openclaw", SHA, "passed" ],
        creator.values_at("schema", "schema_version", "platform", "candidate_sha", "result")
      )
      assert_equal(
        HiveLiveAgentProof.workflow_creator_commands(
          HiveLiveAgentProof::WORKFLOW_CREATOR_EXAMPLE_SLUG
        ),
        creator.fetch("hive_commands")
      )
      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_FILES,
                   creator.fetch("created_files").map { |record| record.fetch("path") }.sort
      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_DESCRIPTOR_SHA256,
                   creator.dig("descriptor", "normalized_sha256")
      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_STAGE_OUTPUT_SHA256,
                   creator.dig("stage_execution", "artifact", "sha256")
      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_STAGE_INSTRUCTION,
                   creator.dig("stage_execution", "instruction", "path")
      assert_equal(
        [ 0, 1, false, 1 ],
        [
          creator.fetch("creation_only_task_count"),
          creator.fetch("task_count"),
          creator.dig("task", "retry_created"),
          creator.dig("task", "run_count")
        ]
      )
      assert_match(/hive-cli-1\.2\.3\.gem\z/, verified.fetch("gem"))
      assert_match(/hive-agent-skills-#{SHA}\.tar\.gz\z/, verified.fetch("skills"))
    end
  end

  def test_attestor_rejects_missing_skipped_or_unsafe_platform_evidence
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      FileUtils.rm_f(File.join(evidence, "pi.json"))
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-missing"))
      end
      assert_includes error.message, "exactly"

      evidence = prepare_evidence(dir, artifacts)
      row_path = File.join(evidence, "codex.json")
      row = JSON.parse(File.read(row_path))
      row["result"] = "skipped"
      HiveLiveAgentProof.write_json(row_path, row)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-skipped"))
      end
      assert_includes error.message, "invalid"

      row["result"] = "passed"
      row["hive_commands"] << [ "act", "resume", "proof:live-agent-skill" ]
      HiveLiveAgentProof.write_json(row_path, row)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-unsafe"))
      end
      assert_includes error.message, "exactly one operational status"

      evidence = prepare_evidence(dir, artifacts)
      row_path = File.join(evidence, "claude.json")
      row = JSON.parse(File.read(row_path))
      row["native_activation"] = {
        "kind" => "generic-file-read", "invocation" => "/hive"
      }
      HiveLiveAgentProof.write_json(row_path, row)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-generic-activation"))
      end
      assert_includes error.message, "native activation"
    end
  end

  def test_attestor_rejects_workflow_creator_mutation_or_graph_drift
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(row_path))
      row["task_count"] = 2
      HiveLiveAgentProof.write_json(row_path, row)

      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-task"))
      end
      assert_includes error.message, "unauthorized side effect"

      creator_evidence = prepare_creator_evidence(dir, artifacts)
      row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(row_path))
      row["validation"]["stages"] << "publish"
      HiveLiveAgentProof.write_json(row_path, row)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-publish"))
      end
      assert_includes error.message, "normalized graph"

      creator_evidence = prepare_creator_evidence(dir, artifacts)
      row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(row_path))
      row["descriptor"]["normalized_sha256"] = "0" * 64
      HiveLiveAgentProof.write_json(row_path, row)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-descriptor"))
      end
      assert_includes error.message, "descriptor contract"

      creator_evidence = prepare_creator_evidence(dir, artifacts)
      row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(row_path))
      descriptor_file = row.fetch("created_files").find do |record|
        record.fetch("path") == ".hive-state/workflows/editorial.yml"
      end
      descriptor_file["sha256"] = "0" * 64
      HiveLiveAgentProof.write_json(row_path, row)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(
          artifacts, evidence, creator_evidence,
          File.join(dir, "proof-descriptor-file")
        )
      end
      assert_includes error.message, "descriptor contract"

      creator_evidence = prepare_creator_evidence(dir, artifacts)
      row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(row_path))
      row.dig("stage_execution", "artifact")["sha256"] = "0" * 64
      HiveLiveAgentProof.write_json(row_path, row)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-stage"))
      end
      assert_includes error.message, "nested stage evidence"

      creator_evidence = prepare_creator_evidence(dir, artifacts)
      row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(row_path))
      row.dig("stage_execution", "instruction")["sha256"] = "not-a-digest"
      HiveLiveAgentProof.write_json(row_path, row)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(
          artifacts, evidence, creator_evidence,
          File.join(dir, "proof-stage-instruction")
        )
      end
      assert_includes error.message, "nested stage evidence"
    end
  end

  def test_attestor_rejects_missing_reordered_duplicate_or_extra_creator_commands
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      expected = HiveLiveAgentProof.workflow_creator_commands(
        HiveLiveAgentProof::WORKFLOW_CREATOR_EXAMPLE_SLUG
      )
      command_variants = {
        "missing" => expected.first(expected.length - 1),
        "reordered" => expected.map(&:dup).tap { |commands| commands[0], commands[1] = commands[1], commands[0] },
        "duplicate" => expected.map(&:dup).insert(1, expected.first.dup),
        "extra" => expected.map(&:dup).push([ "doctor", "--json" ])
      }

      command_variants.each do |name, commands|
        creator_evidence = prepare_creator_evidence(File.join(dir, name), artifacts)
        row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
        row = JSON.parse(File.read(row_path))
        row["hive_commands"] = commands
        HiveLiveAgentProof.write_json(row_path, row)

        error = assert_raises(HiveLiveAgentProof::Error) do
          attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-#{name}"))
        end
        assert_equal "workflow-creator prompt or command sequence is invalid", error.message
      end
    end
  end

  def test_attestor_rejects_task_slug_or_retry_binding_drift
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      variants = {
        "first_slug" => "different-first-260728-abcd",
        "retry_slug" => "different-retry-260728-abcd"
      }

      variants.each do |field, value|
        creator_evidence = prepare_creator_evidence(File.join(dir, field), artifacts)
        row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
        row = JSON.parse(File.read(row_path))
        row.fetch("task")[field] = value
        HiveLiveAgentProof.write_json(row_path, row)

        error = assert_raises(HiveLiveAgentProof::Error) do
          attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-#{field}"))
        end
        assert_includes error.message, "unauthorized side effect"
      end
    end
  end

  def test_attestor_rejects_runtime_package_identity_version_or_teardown_drift
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      mutations = {
        "gateway_alias" => lambda do |row|
          row.dig("executables", "audit_gateway")["realpath"] =
            row.dig("executables", "candidate", "realpath")
        end,
        "gateway_runtime_manifest" => lambda do |row|
          row.dig("executables", "audit_gateway", "runtime_bundle")["manifest_sha256"] =
            "0" * 64
        end,
        "openclaw_version" => lambda do |row|
          row.dig("executables", "openclaw")["version"] = "OpenClaw 2026.7.2 (wrong)"
        end,
        "nested_stage_fixture" => lambda do |row|
          row.dig("executables", "nested_stage_fixture")["sha256"] = "not-a-digest"
        end,
        "package_version" => lambda do |row|
          row.fetch("openclaw_package")["version"] = "2026.7.2"
        end,
        "package_integrity" => lambda do |row|
          row.fetch("openclaw_package")["integrity"] = "sha512-substituted"
        end,
        "package_lock" => lambda do |row|
          row.fetch("openclaw_package")["lock_sha256"] = "0" * 64
        end,
        "package_unverified" => lambda do |row|
          row.fetch("openclaw_package")["verified"] = false
        end,
        "effect_policy" => lambda do |row|
          row.fetch("effect_policy")["allowed_executables"] = [ "/proof/candidate-hive" ]
        end,
        "effect_observation_absent" => lambda do |row|
          row.delete("effect_observations")
        end,
        "network_observation_absent" => lambda do |row|
          row.fetch("processes").fetch(0).delete("network")
        end,
        "interrupted" => lambda do |row|
          row.fetch("processes").fetch(0)["interrupted"] = true
        end,
        "teardown" => lambda do |row|
          row["teardown"]["status"] = "failed"
        end
      }

      mutations.each do |name, mutation|
        creator_evidence = prepare_creator_evidence(File.join(dir, name), artifacts)
        row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
        row = JSON.parse(File.read(row_path))
        mutation.call(row)
        HiveLiveAgentProof.write_json(row_path, row)

        error = assert_raises(HiveLiveAgentProof::Error) do
          attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-#{name}"))
        end
        assert_includes error.message, "runtime identity or teardown"
      end
    end
  end

  def test_verifier_rejects_openclaw_package_identity_with_a_matching_digest
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      proof = File.join(dir, "proof")
      attest(artifacts, evidence, creator_evidence, proof)
      attestation_path = File.join(proof, "attestation.json")
      attestation = JSON.parse(File.read(attestation_path))
      attestation.dig("workflow_creator", "openclaw_package")["integrity"] =
        "sha512-substituted"
      HiveLiveAgentProof.write_json(attestation_path, attestation)
      digest = HiveLiveAgentProof.sha256(attestation_path)

      error = assert_raises(HiveLiveAgentProof::Error) do
        verifier(proof, digest).call
      end
      assert_includes error.message, "attested runtime evidence"
    end
  end

  def test_verifier_fails_closed_on_check_digest_identity_and_artifact_substitution
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      proof = File.join(dir, "proof")
      result = attest(artifacts, evidence, creator_evidence, proof)

      assert_raises(HiveLiveAgentProof::Error) do
        verifier(proof, "0" * 64).call
      end
      assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::Verifier.new(
          proof_dir: proof, candidate_sha: "c" * 40, workflow_revision: WORKFLOW_SHA,
          repository: REPOSITORY, run_id: "42", run_attempt: "1", attestation_sha256: result.fetch("sha256")
        ).call
      end

      gem = Dir[File.join(proof, "artifacts", "*.gem")].fetch(0)
      File.open(gem, "ab") { |file| file.write("substitution") }
      error = assert_raises(HiveLiveAgentProof::Error) { verifier(proof, result.fetch("sha256")).call }
      assert_includes error.message, "digest mismatch"
    end
  end

  def test_secret_scanner_rejects_provider_and_private_key_shapes
    refute_empty HiveLiveAgentProof.secret_findings("sk-ant-abcdefghijklmnopqrstuvwxyz")
    refute_empty HiveLiveAgentProof.secret_findings("-----BEGIN PRIVATE KEY-----")
    refute_empty HiveLiveAgentProof.secret_findings("prefix exact-value suffix", exact_secrets: [ "exact-value" ])
    assert_empty HiveLiveAgentProof.secret_findings('{"result":"passed","sha256":"abc"}')
  end

  private

  def build(gem, source, output, canonical)
    HiveLiveAgentProof::Builder.new(
      candidate_sha: SHA, gem_path: gem, source_archive: source,
      output_dir: output, canonical: canonical
    ).call
  end

  def prepare_artifacts(dir)
    artifacts = File.join(dir, "candidate")
    gem = write_file(File.join(dir, "hive-cli-1.2.3.gem"), "gem-bytes")
    source = write_file(File.join(dir, "source.tar.gz"), "source-bytes")
    build(gem, source, artifacts, Hive::AgentSkills::CanonicalSkill.new)
    artifacts
  end

  def prepare_release_artifacts(dir, canonical)
    FileUtils.mkdir_p(dir)
    artifacts = File.join(dir, "release-candidate")
    gem = write_file(File.join(dir, "hive-cli-#{Hive::VERSION}.gem"), "gem-bytes")
    source = write_file(File.join(dir, "source.tar.gz"), "source-bytes")
    build(gem, source, artifacts, canonical)
    artifacts
  end

  def verify_candidate(artifacts, canonical, **options)
    HiveLiveAgentProof::CandidateVerifier.new(
      candidate_dir: artifacts,
      candidate_sha: SHA,
      expected_hive_version: Hive::VERSION,
      canonical: canonical,
      **options
    ).call
  end

  def prepare_evidence(dir, artifacts)
    evidence = File.join(dir, "evidence")
    FileUtils.rm_rf(evidence)
    FileUtils.mkdir_p(evidence)
    manifest = JSON.parse(File.read(File.join(artifacts, "artifact-manifest.json")))
    HiveLiveAgentProof::PLATFORMS.each do |platform|
      row = {
        "schema" => "hive-live-agent-skill-evidence",
        "schema_version" => 1,
        "platform" => platform,
        "candidate_sha" => SHA,
        "result" => "passed",
        "agent" => { "binary" => platform, "version" => "1.0.0" },
        "hive" => { "version" => Hive::VERSION },
        "skill" => {
          "invocation" => Hive::AgentSkills::CanonicalSkill.new.render(platform).invocation,
          "skill_version" => manifest.fetch("skill_version"),
          "canonical_digest" => manifest.fetch("canonical_digest")
        },
        "native_activation" => {
          "kind" => HiveLiveAgentProof::NATIVE_ACTIVATION_KINDS.fetch(platform),
          "invocation" => HiveLiveAgentProof::INVOCATIONS.fetch(platform)
        },
        "hive_commands" => HiveLiveAgentProof::OBSERVATION_COMMANDS,
        "secret_scan" => { "status" => "passed" },
        "cleanup" => { "status" => "passed" }
      }
      HiveLiveAgentProof.write_json(File.join(evidence, "#{platform}.json"), row)
    end
    evidence
  end

  def prepare_creator_evidence(dir, artifacts)
    evidence = File.join(dir, "creator-evidence")
    FileUtils.rm_rf(evidence)
    FileUtils.mkdir_p(evidence)
    manifest = JSON.parse(File.read(File.join(artifacts, "artifact-manifest.json")))
    gateway_runtime_files = %w[
      attempt_ledger.rb candidate_identity.rb candidate_executor.rb result_ledger.rb
      task_binding.rb main.rb
    ].each_with_index.map do |name, index|
      { "name" => name, "sha256" => (index + 8).to_s(16) * 64 }
    end
    gateway_runtime_config_sha = "c" * 64
    gateway_runtime_manifest_sha = Digest::SHA256.hexdigest(
      JSON.generate(
        "config_sha256" => gateway_runtime_config_sha,
        "files" => gateway_runtime_files
      )
    )
    row = {
      "schema" => "hive-live-workflow-creator-evidence",
      "schema_version" => 1,
      "platform" => "openclaw",
      "candidate_sha" => SHA,
      "result" => "passed",
      "provider" => {
        "name" => "openai",
        "model" => "openai/gpt-5.6",
        "credential_environment" => "OPENAI_API_KEY"
      },
      "openclaw_package" => {
        "version" => HiveLiveAgentProof::WORKFLOW_CREATOR_OPENCLAW_VERSION,
        "integrity" => HiveLiveAgentProof::WORKFLOW_CREATOR_OPENCLAW_INTEGRITY,
        "lock_sha256" => HiveLiveAgentProof::WORKFLOW_CREATOR_OPENCLAW_LOCK_SHA256,
        "package_count" => HiveLiveAgentProof::WORKFLOW_CREATOR_OPENCLAW_PACKAGE_COUNT,
        "receipt_sha256" => "6" * 64,
        "verified" => true
      },
      "executables" => {
        "candidate" => {
          "configured_path" => "/proof/candidate-hive",
          "realpath" => "/proof/candidate-hive",
          "sha256" => "1" * 64
        },
        "audit_gateway" => {
          "configured_path" => "/proof/gateway/bin/hive",
          "realpath" => "/proof/gateway/bin/hive",
          "sha256" => "2" * 64,
          "runtime_bundle" => {
            "schema" => "hive-openclaw-audit-gateway-runtime",
            "schema_version" => 1,
            "config_sha256" => gateway_runtime_config_sha,
            "manifest_sha256" => gateway_runtime_manifest_sha,
            "files" => gateway_runtime_files
          }
        },
        "openclaw" => {
          "configured_path" => "/proof/openclaw",
          "realpath" => "/proof/openclaw",
          "sha256" => "3" * 64,
          "version" => "OpenClaw 2026.7.1-beta.2 (fixture)"
        },
        "nested_stage_fixture" => {
          "configured_path" => "/proof/fixture-bin/claude",
          "realpath" => "/proof/fixture-bin/claude",
          "sha256" => "5" * 64
        }
      },
      "openclaw_configuration" => {
        "sha256" => "4" * 64,
        "approvals_sha256" => "7" * 64,
        "path_prepend" => [ "/proof/gateway/bin" ]
      },
      "effect_policy" => {
        "status" => "enforced",
        "allowed_tools" => %w[read write edit apply_patch exec],
        "allowed_executables" => [ "/proof/gateway/bin/hive" ],
        "runtime_source" => "openclaw-exact-runtime",
        "proof_mode" => "direct_native_tool_surface",
        "driver_sha256" => "a" * 64,
        "native_tool_receipt_sha256" => "b" * 64,
        "monitored_surfaces" => %w[
          workspace_filesystem outside_sibling_write_edit_apply_patch
          exec_allowlist_and_shell_composition configured_tool_inventory
        ],
        "outside_read_caveat" => {
          "global_denial_claimed" => false,
          "caveat" => "Pinned beta permits configured skill-root reads."
        },
        "configuration_sha256" => "4" * 64,
        "approvals_sha256" => "7" * 64
      },
      "effect_observations" => {
        "status" => "observed",
        "policy_sha256" => "8" * 64,
        "filesystem_receipt_sha256" => "9" * 64,
        "filesystem_observation_count" => 2,
        "filesystem_mutation_count" => 3,
        "network_observation_count" => 1,
        "network_socket_count" => 1,
        "network_observations" => [
          {
            "protocol" => "tcp4",
            "remote" => "0100007F:01BB",
            "state" => "01",
            "kind" => "network",
            "operation" => "connection",
            "window" => "workflow_creation",
            "classification" => "unattributed_agent_window"
          }
        ],
        "negative_control_count" => 7,
        "authoring" => {
          "proof_mode" => "credentialed_openclaw_agent",
          "model_loop" => "executed",
          "driver_sha256" => "a" * 64,
          "receipt_sha256" => nil
        }
      },
      "processes" => [
        {
          "label" => "workflow_creation",
          "timed_out" => false,
          "interrupted" => false,
          "network" => {
            "status" => "observed",
            "sample_count" => 1,
            "socket_count" => 1,
            "sockets" => [
              { "protocol" => "tcp4", "remote" => "0100007F:01BB", "state" => "01" }
            ]
          },
          "teardown" => {
            "status" => "passed",
            "reaped" => true,
            "readers" => "complete",
            "writer" => "complete",
            "descendants" => "none",
            "containment" => "linux_child_subreaper"
          }
        }
      ],
      "teardown" => {
        "status" => "passed",
        "reaped" => true,
        "descendants" => "none",
        "containment" => "linux_child_subreaper"
      },
      "prompt_sha256" => Digest::SHA256.hexdigest(HiveLiveAgentProof::WORKFLOW_CREATOR_PROMPT),
      "task_prompt_sha256" =>
        Digest::SHA256.hexdigest(HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_PROMPT),
      "skill" => {
        "skill_version" => manifest.fetch("skill_version"),
        "canonical_digest" => manifest.fetch("canonical_digest")
      },
      "native_activation" => {
        "kind" => HiveLiveAgentProof::NATIVE_ACTIVATION_KINDS.fetch("openclaw"),
        "invocation" => HiveLiveAgentProof::INVOCATIONS.fetch("openclaw")
      },
      "hive_commands" => HiveLiveAgentProof.workflow_creator_commands(
        HiveLiveAgentProof::WORKFLOW_CREATOR_EXAMPLE_SLUG
      ),
      "created_files" => HiveLiveAgentProof::WORKFLOW_CREATOR_FILES.map do |path|
        { "path" => path, "sha256" => "c" * 64, "size" => 10 }
      end,
      "descriptor" => {
        "path" => ".hive-state/workflows/editorial.yml",
        "sha256" => "c" * 64,
        "normalized_sha256" => HiveLiveAgentProof::WORKFLOW_CREATOR_DESCRIPTOR_SHA256,
        "agent_model_inheritance" => "project"
      },
      "validation" => {
        "valid" => true,
        "stages" => %w[research draft approval],
        "automatic_edges" => [ %w[research draft], %w[draft approval] ],
        "human_outcomes" => [
          { "stage" => "approval", "name" => "approve", "complete" => true,
            "artifact" => "draft.md", "to" => nil },
          { "stage" => "approval", "name" => "reject", "complete" => false,
            "artifact" => nil, "to" => "draft" }
        ]
      },
      "creation_only_task_count" => 0,
      "task_count" => 1,
      "task" => {
        "slug" => HiveLiveAgentProof::WORKFLOW_CREATOR_EXAMPLE_SLUG,
        "first_slug" => HiveLiveAgentProof::WORKFLOW_CREATOR_EXAMPLE_SLUG,
        "retry_slug" => HiveLiveAgentProof::WORKFLOW_CREATOR_EXAMPLE_SLUG,
        "workflow" => "editorial",
        "first_created" => true,
        "retry_created" => false,
        "run_count" => 1,
        "current_stage" => "1-research"
      },
      "stage_execution" => {
        "provider" => "claude",
        "provider_version" => "2.1.118",
        "stage" => "research",
        "task_slug" => HiveLiveAgentProof::WORKFLOW_CREATOR_EXAMPLE_SLUG,
        "instruction" => {
          "path" => HiveLiveAgentProof::WORKFLOW_CREATOR_STAGE_INSTRUCTION,
          "sha256" => "e" * 64,
          "size" => 42
        },
        "artifact" => {
          "path" => HiveLiveAgentProof::WORKFLOW_CREATOR_STAGE_FILE,
          "sha256" => HiveLiveAgentProof::WORKFLOW_CREATOR_STAGE_OUTPUT_SHA256,
          "size" => HiveLiveAgentProof::WORKFLOW_CREATOR_STAGE_OUTPUT.bytesize,
          "marker" => "complete",
          "changed" => true
        },
        "fixture" => {
          "sha256" => "5" * 64,
          "receipt_sha256" => "d" * 64,
          "invocation_count" => 1
        },
        "prompt_sha256" => "a" * 64,
        "argv_sha256" => "b" * 64
      },
      "unauthorized_effects_observed" => [],
      "external_actions" => [],
      "external_actions_scope" => {
        "derivation" => "scoped_policy_and_filesystem_observations",
        "monitored_surfaces" => %w[
          workspace_filesystem outside_sibling_write_edit_apply_patch
          exec_allowlist_and_shell_composition configured_tool_inventory
          workspace_before_after_snapshots
        ],
        "observed_unadjudicated_surfaces" => [ "process_socket_snapshots" ],
        "network_authorization" => "unverified",
        "global_effect_absence_claimed" => false,
        "limitations" => [
          "Pinned beta permits configured skill-root reads.",
          "socket snapshots retain unattributed observations; destination identity " \
            "and authorization are not adjudicated"
        ]
      },
      "secret_scan" => { "status" => "passed" },
      "cleanup" => { "status" => "passed" }
    }
    HiveLiveAgentProof.write_json(File.join(evidence, "openclaw-workflow-creator.json"), row)
    evidence
  end

  def attest(artifacts, evidence, creator_evidence, proof)
    HiveLiveAgentProof::Attestor.new(
      candidate_sha: SHA, workflow_revision: WORKFLOW_SHA, repository: REPOSITORY,
      run_id: "42", run_attempt: "1", artifact_dir: artifacts,
      evidence_dir: evidence, creator_evidence_dir: creator_evidence, output_dir: proof
    ).call
  end

  def verifier(proof, digest)
    HiveLiveAgentProof::Verifier.new(
      proof_dir: proof, candidate_sha: SHA, workflow_revision: WORKFLOW_SHA,
      repository: REPOSITORY, run_id: "42", run_attempt: "1", attestation_sha256: digest
    )
  end

  def write_file(path, content)
    File.write(path, content)
    path
  end

  def refresh_artifact_record(artifacts, path)
    manifest_path = File.join(artifacts, "artifact-manifest.json")
    manifest = JSON.parse(File.read(manifest_path))
    record = manifest.fetch("files").fetch(File.basename(path))
    record["sha256"] = HiveLiveAgentProof.sha256(path)
    record["size"] = File.size(path)
    HiveLiveAgentProof.write_json(manifest_path, manifest)
  end

  def write_declared_size_archive(path, name:, size:)
    header = Gem::Package::TarHeader.new(
      name: name,
      size: size,
      prefix: "",
      mode: 0o600,
      typeflag: "0",
      linkname: ""
    )
    Zlib::GzipWriter.open(path) do |gzip|
      gzip.write(header.to_s)
      gzip.write("\0" * 1_024)
    end
  end

  def write_test_archive(path, files)
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        files.each do |name, content|
          tar.add_file_simple(name, 0o600, content.bytesize) do |entry|
            entry.write(content)
          end
        end
      end
    end
  end
end
