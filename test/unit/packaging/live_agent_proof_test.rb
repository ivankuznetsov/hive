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

      assert_match(/hive-cli-1\.2\.3\.gem\z/, verified.fetch("gem"))
      assert_match(/hive-agent-skills-#{SHA}\.tar\.gz\z/, verified.fetch("skills"))
    end
  end

  def test_workflow_creator_schema_v1_vocabulary_and_bytes_are_exact
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(path))

      assert_equal(
        %w[
          candidate_sha cleanup created_files creation_only_task_count
          external_actions hive_commands native_activation platform
          prompt_sha256 result schema schema_version secret_scan skill task
          task_count task_prompt_sha256 validation
        ],
        row.keys.sort
      )
      assert_equal(
        <<~PROMPT,
          /hive
          Create a three-stage editorial workflow that researches, drafts, and requires approval before publishing.
          Use the installed Hive workflow-creator capability in this initialized project.
          This is creation-only: validate the result, report the defaults, and do not create or run a task.
        PROMPT
        HiveLiveAgentProof::WORKFLOW_CREATOR_PROMPT
      )
      assert_equal(
        <<~PROMPT,
          /hive
          Use the validated editorial workflow to create and run one task for:
          "Research and draft the launch announcement for approval."
          Use idempotency key workflow-creator-proof:editorial:live-proof. In this exact order: create the task,
          run its first stage once, repeat the same creation command once to prove the retry is a no-op,
          then query operational status. Do not publish or perform any other external action.
        PROMPT
        HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_PROMPT
      )
      assert_equal(
        [
          [ "version" ],
          [ "workflow", "list", "--json" ],
          [ "workflow", "new", "editorial", "--json" ],
          [ "workflow", "validate", "editorial", "--json" ],
          [ "workflow", "commit", "editorial" ],
          [ "new", "workflow-creator-proof", "--workflow", "editorial",
            "--idempotency-key", "workflow-creator-proof:editorial:live-proof",
            "--json", "Research and draft the launch announcement for approval." ],
          [ "run", "editorial-live-proof" ],
          [ "new", "workflow-creator-proof", "--workflow", "editorial",
            "--idempotency-key", "workflow-creator-proof:editorial:live-proof",
            "--json", "Research and draft the launch announcement for approval." ],
          [ "status", "--operational", "--json" ]
        ],
        HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS
      )
      assert_equal(
        %w[
          .hive-state/workflows/editorial.yml
          .hive-state/workflows/editorial/draft.md
          .hive-state/workflows/editorial/research.md
        ],
        HiveLiveAgentProof::WORKFLOW_CREATOR_FILES
      )
      assert_equal "#{JSON.pretty_generate(row)}\n", File.binread(path)
    end
  end

  def test_attestor_and_verifier_preserve_public_and_unrelated_proof_bytes
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      creator_path = File.join(
        creator_evidence,
        "openclaw-workflow-creator.json"
      )
      creator_bytes = File.binread(creator_path)
      creator_row = JSON.parse(creator_bytes)
      platform_rows = HiveLiveAgentProof::PLATFORMS.to_h do |platform|
        [ platform, JSON.parse(File.read(File.join(evidence, "#{platform}.json"))) ]
      end
      manifest = JSON.parse(File.read(File.join(artifacts, "artifact-manifest.json")))
      proof = File.join(dir, "proof")

      result = attest(artifacts, evidence, creator_evidence, proof)
      attestation = result.fetch("attestation")

      assert_equal creator_row, attestation.fetch("workflow_creator")
      assert_equal creator_bytes,
                   File.binread(File.join(proof, "evidence", "openclaw-workflow-creator.json"))
      assert_equal manifest, attestation.fetch("artifacts")
      assert_equal platform_rows, attestation.fetch("platforms")
      assert_equal 6, attestation.dig("secret_scan", "files_scanned")
      assert_equal(
        "#{result.fetch("sha256")}  attestation.json\n",
        File.binread(File.join(proof, "attestation.sha256"))
      )

      FileUtils.rm_rf(creator_evidence)
      verified = verifier(proof, result.fetch("sha256")).call
      assert_match(/hive-cli-1\.2\.3\.gem\z/, verified.fetch("gem"))
    end
  end

  def test_current_creator_failures_have_exact_public_messages
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      cases = {
        "missing-inventory" => [
          ->(root, _row) { FileUtils.rm_f(File.join(root, "openclaw-workflow-creator.json")) },
          "workflow-creator evidence must contain exactly openclaw-workflow-creator.json"
        ],
        "extra-inventory" => [
          ->(root, _row) { HiveLiveAgentProof.write_json(File.join(root, "extra.json"), {}) },
          "workflow-creator evidence must contain exactly openclaw-workflow-creator.json"
        ],
        "identity" => [
          ->(_root, row) { row["schema"] = "wrong" },
          "workflow-creator evidence identity or result is invalid"
        ],
        "provenance" => [
          ->(_root, row) { row["skill"]["canonical_digest"] = "0" * 64 },
          "workflow-creator evidence canonical provenance mismatch"
        ],
        "activation" => [
          ->(_root, row) { row["native_activation"]["kind"] = "generic-file-read" },
          "workflow-creator native activation evidence is invalid"
        ],
        "missing-command" => [
          ->(_root, row) { row["hive_commands"].pop },
          "workflow-creator prompt or command sequence is invalid"
        ],
        "reordered-command" => [
          lambda do |_root, row|
            row["hive_commands"][0], row["hive_commands"][1] =
              row["hive_commands"][1], row["hive_commands"][0]
          end,
          "workflow-creator prompt or command sequence is invalid"
        ],
        "duplicate-command" => [
          ->(_root, row) { row["hive_commands"].insert(1, row["hive_commands"].first) },
          "workflow-creator prompt or command sequence is invalid"
        ],
        "extra-command" => [
          ->(_root, row) { row["hive_commands"] << [ "doctor", "--json" ] },
          "workflow-creator prompt or command sequence is invalid"
        ],
        "missing-created-file" => [
          ->(_root, row) { row["created_files"].pop },
          "workflow-creator created files are incomplete"
        ],
        "invalid-file" => [
          ->(_root, row) { row["created_files"].first["size"] = 0 },
          "workflow-creator created-file records are invalid"
        ],
        "missing-validation" => [
          ->(_root, row) { row["validation"] = nil },
          "workflow-creator normalized graph is invalid"
        ],
        "graph-drift" => [
          ->(_root, row) { row["validation"]["stages"] << "publish" },
          "workflow-creator normalized graph is invalid"
        ],
        "unauthorized-task" => [
          ->(_root, row) { row["task_count"] = 2 },
          "workflow-creator proof contains an unauthorized side effect"
        ],
        "unauthorized-effect" => [
          ->(_root, row) { row["external_actions"] << "publish" },
          "workflow-creator proof contains an unauthorized side effect"
        ],
        "secret-scan-status" => [
          ->(_root, row) { row["secret_scan"]["status"] = "failed" },
          "workflow-creator evidence lacks secret-scan or cleanup proof"
        ],
        "cleanup-status" => [
          ->(_root, row) { row["cleanup"]["status"] = "failed" },
          "workflow-creator evidence lacks secret-scan or cleanup proof"
        ],
        "secret-content" => [
          ->(_root, row) { row["diagnostic"] = [ "sk", "ant", "abcdefghijkl" ].join("-") },
          "workflow-creator evidence secret scan failed: pattern:sk-ant-[A-Za-z0-9_-]{12,}"
        ]
      }

      cases.each do |label, (mutation, expected_message)|
        creator = prepare_creator_evidence(File.join(dir, label), artifacts)
        path = File.join(creator, "openclaw-workflow-creator.json")
        row = JSON.parse(File.read(path))
        mutation.call(creator, row)
        HiveLiveAgentProof.write_json(path, row) if File.exist?(path)

        error = assert_raises(HiveLiveAgentProof::Error, label) do
          attest(artifacts, evidence, creator, File.join(dir, "proof-#{label}"))
        end
        assert_equal expected_message, error.message, label
      end

      creator = prepare_creator_evidence(File.join(dir, "verifier-source"), artifacts)
      source_proof = File.join(dir, "verifier-source-proof")
      attest(artifacts, evidence, creator, source_proof)
      verifier_cases = {
        "identity" => [
          ->(row) { row["platform"] = "wrong" },
          "workflow-creator attested evidence is incomplete"
        ],
        "activation" => [
          ->(row) { row["native_activation"]["kind"] = "generic-file-read" },
          "workflow-creator attested native activation evidence is invalid"
        ],
        "contract" => [
          ->(row) { row["prompt_sha256"] = "0" * 64 },
          "workflow-creator attested contract is invalid"
        ]
      }
      verifier_cases.each do |label, (mutation, expected_message)|
        proof = File.join(dir, "verifier-proof-#{label}")
        FileUtils.cp_r(source_proof, proof)
        attestation_path = File.join(proof, "attestation.json")
        attestation = JSON.parse(File.read(attestation_path))
        mutation.call(attestation.fetch("workflow_creator"))
        HiveLiveAgentProof.write_json(attestation_path, attestation)

        error = assert_raises(HiveLiveAgentProof::Error, label) do
          verifier(proof, HiveLiveAgentProof.sha256(attestation_path)).call
        end
        assert_equal expected_message, error.message, label
      end
    end
  end

  # These accepted mutations are characterization of the current duplicated
  # verifier. They are tightening targets for U1a1/U1a2, not compatibility promises.
  def test_current_verifier_acceptance_gaps_are_explicit
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      source_proof = File.join(dir, "source-proof")
      attest(artifacts, evidence, creator_evidence, source_proof)
      cases = {
        "extra-field" => ->(row) { row["unexpected"] = true },
        "schema-version" => ->(row) { row["schema_version"] = 999 },
        "skill-version" => ->(row) { row["skill"]["skill_version"] = "wrong" },
        "created-file" => lambda do |row|
          row["created_files"].first["sha256"] = "0" * 64
          row["created_files"].first["size"] = 0
        end,
        "graph" => ->(row) { row["validation"]["stages"] << "publish" }
      }

      cases.each do |label, mutation|
        proof = File.join(dir, "proof-#{label}")
        FileUtils.cp_r(source_proof, proof)
        attestation_path = File.join(proof, "attestation.json")
        attestation = JSON.parse(File.read(attestation_path))
        mutation.call(attestation.fetch("workflow_creator"))
        HiveLiveAgentProof.write_json(attestation_path, attestation)

        verified = verifier(
          proof,
          HiveLiveAgentProof.sha256(attestation_path)
        ).call
        assert_match(/hive-cli-1\.2\.3\.gem\z/, verified.fetch("gem"), label)
      end
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
    refute_empty HiveLiveAgentProof.secret_findings(%w[sk ant abcdefghijklmnopqrstuvwxyz].join("-"))
    refute_empty HiveLiveAgentProof.secret_findings([ "-----BEGIN", "PRIVATE", "KEY-----" ].join(" "))
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

  def verify_candidate(artifacts, canonical)
    HiveLiveAgentProof::CandidateVerifier.new(
      candidate_dir: artifacts,
      candidate_sha: SHA,
      expected_hive_version: Hive::VERSION,
      canonical: canonical
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
      "hive_commands" => HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS,
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
        "slug" => HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_SLUG,
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
end
