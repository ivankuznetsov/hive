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
        "openclaw_version" => lambda do |row|
          row.dig("executables", "openclaw")["version"] = "OpenClaw 2026.7.2 (wrong)"
        end,
        "package_version" => lambda do |row|
          row.fetch("openclaw_package")["version"] = "2026.7.2"
        end,
        "package_integrity" => lambda do |row|
          row.fetch("openclaw_package")["integrity"] = "sha512-substituted"
        end,
        "package_unverified" => lambda do |row|
          row.fetch("openclaw_package")["verified"] = false
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
          "sha256" => "2" * 64
        },
        "openclaw" => {
          "configured_path" => "/proof/openclaw",
          "realpath" => "/proof/openclaw",
          "sha256" => "3" * 64,
          "version" => "OpenClaw 2026.7.1-beta.2 (fixture)"
        }
      },
      "openclaw_configuration" => {
        "sha256" => "4" * 64,
        "path_prepend" => [ "/proof/gateway/bin" ]
      },
      "processes" => [
        {
          "label" => "workflow_creation",
          "timed_out" => false,
          "teardown" => {
            "status" => "passed",
            "reaped" => true,
            "readers" => "complete",
            "writer" => "complete",
            "descendants" => "none"
          }
        }
      ],
      "teardown" => {
        "status" => "passed",
        "reaped" => true,
        "descendants" => "none"
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
      "external_actions" => [],
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
