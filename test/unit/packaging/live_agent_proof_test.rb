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
          candidate_sha cleanup containment created_files
          creation_only_task_count evidence_bundle executed_instruction
          execution_kind external_actions hive_commands model_loop
          native_activation platform prompt_sha256 result schema
          schema_version secret_scan skill task task_count
          task_prompt_sha256 teardown validation
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
      creator_bundle_bytes = HiveLiveAgentProof::WORKFLOW_CREATOR_BUNDLE_FILES.to_h do |name|
        [ name, File.binread(File.join(creator_evidence, name)) ]
      end
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
      creator_bundle_bytes.each do |name, bytes|
        assert_equal bytes, File.binread(File.join(proof, "evidence", name)), name
      end
      assert_equal manifest, attestation.fetch("artifacts")
      assert_equal platform_rows, attestation.fetch("platforms")
      assert_equal 9, attestation.dig("secret_scan", "files_scanned")
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
          "workflow-creator bundle inventory is invalid"
        ],
        "extra-inventory" => [
          ->(root, _row) { HiveLiveAgentProof.write_json(File.join(root, "extra.json"), {}) },
          "workflow-creator bundle inventory is invalid"
        ],
        "identity" => [
          ->(_root, row) { row["schema"] = "wrong" },
          "workflow-creator evidence identity or result is invalid"
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
        "invalid-file" => [
          ->(_root, row) { row["created_files"].first["size"] = 0 },
          "workflow-creator created-file records are invalid"
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
          "workflow-creator retained primary does not match attestation"
        ],
        "activation" => [
          ->(row) { row["native_activation"]["kind"] = "generic-file-read" },
          "workflow-creator retained primary does not match attestation"
        ],
        "contract" => [
          ->(row) { row["prompt_sha256"] = "0" * 64 },
          "workflow-creator retained primary does not match attestation"
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

  def test_verifier_rejects_previous_creator_acceptance_gaps
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
        retained_path = File.join(proof, "evidence", "openclaw-workflow-creator.json")
        retained = JSON.parse(File.read(retained_path))
        mutation.call(retained)
        attestation["workflow_creator"] = retained
        HiveLiveAgentProof.write_json(retained_path, retained)
        HiveLiveAgentProof.write_json(attestation_path, attestation)

        error = assert_raises(HiveLiveAgentProof::Error, label) do
          verifier(proof, HiveLiveAgentProof.sha256(attestation_path)).call
        end
        assert_match(/workflow-creator/, error.message, label)
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

  def test_attestor_requires_an_exact_owner_private_four_file_creator_bundle
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)

      creator = prepare_creator_evidence(File.join(dir, "old-single-file"), artifacts)
      HiveLiveAgentProof::WORKFLOW_CREATOR_BUNDLE_FILES.drop(1).each do |name|
        FileUtils.rm_f(File.join(creator, name))
      end
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-old"))
      end
      assert_equal "workflow-creator bundle inventory is invalid", error.message

      creator = prepare_creator_evidence(File.join(dir, "extra"), artifacts)
      HiveLiveAgentProof.write_json(File.join(creator, "unbound.json"), {})
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-extra"))
      end
      assert_equal "workflow-creator bundle inventory is invalid", error.message

      creator = prepare_creator_evidence(File.join(dir, "permissions"), artifacts)
      File.chmod(0o755, creator)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-permissions"))
      end
      assert_equal "workflow-creator bundle root is not an owner-private directory", error.message

      creator = prepare_creator_evidence(File.join(dir, "symlink"), artifacts)
      target = File.join(dir, "foreign.json")
      FileUtils.mv(File.join(creator, "execution-receipt.json"), target)
      File.symlink(target, File.join(creator, "execution-receipt.json"))
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-symlink"))
      end
      assert_equal "workflow-creator bundle cannot be read safely", error.message
    end
  end

  def test_creator_contract_rejects_previous_type_and_cross_binding_gaps
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      cases = {
        "extra-field" => ->(row) { row["unexpected"] = true },
        "schema-version" => ->(row) { row["schema_version"] = 999 },
        "skill-version" => ->(row) { row["skill"]["skill_version"] = "wrong" },
        "numeric-string-size" => ->(row) { row["created_files"].first["size"] = "10" },
        "numeric-digest" => ->(row) { row["created_files"].first["sha256"] = ("1" * 64).to_i },
        "executed-digest" => ->(row) { row["executed_instruction"]["sha256"] = "d" * 64 },
        "bundle-digest" => ->(row) { row["evidence_bundle"].first["sha256"] = "d" * 64 },
        "cleanup-digest" => ->(row) { row["cleanup"]["receipt_sha256"] = "d" * 64 }
      }

      cases.each do |label, mutation|
        creator = prepare_creator_evidence(File.join(dir, label), artifacts)
        path = File.join(creator, "openclaw-workflow-creator.json")
        row = JSON.parse(File.read(path))
        mutation.call(row)
        HiveLiveAgentProof.write_json(path, row)

        error = assert_raises(HiveLiveAgentProof::Error, label) do
          attest(artifacts, evidence, creator, File.join(dir, "proof-#{label}"))
        end
        assert_match(/workflow-creator/, error.message, label)
      end
    end
  end

  def test_creator_bundle_cross_binds_installations_and_execution_summary
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)

      creator = prepare_creator_evidence(File.join(dir, "candidate-package"), artifacts)
      path = File.join(creator, "candidate-installed-manifest.json")
      installed = JSON.parse(File.read(path))
      installed.fetch("members").last["sha256"] = "d" * 64
      installed["closure_sha256"] = Digest::SHA256.hexdigest(
        canonical_json(installed.fetch("members"))
      )
      HiveLiveAgentProof.write_json(path, installed)
      refresh_creator_bindings(creator)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-candidate-package"))
      end
      assert_equal "workflow-creator candidate installed package does not match the release artifact",
                   error.message

      creator = prepare_creator_evidence(File.join(dir, "openclaw-closure"), artifacts)
      path = File.join(creator, "openclaw-installed-manifest.json")
      installed = JSON.parse(File.read(path))
      installed.fetch("members")[1]["path"] = installed.fetch("members")[0]["path"]
      installed["closure_sha256"] = Digest::SHA256.hexdigest(
        canonical_json(installed.fetch("members"))
      )
      HiveLiveAgentProof.write_json(path, installed)
      refresh_creator_bindings(creator)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-openclaw-closure"))
      end
      assert_equal "workflow-creator openclaw installed manifest identity is invalid",
                   error.message

      creator = prepare_creator_evidence(File.join(dir, "command-digest"), artifacts)
      path = File.join(creator, "execution-receipt.json")
      receipt = JSON.parse(File.read(path))
      receipt["hive_commands_sha256"] = "d" * 64
      HiveLiveAgentProof.write_json(path, receipt)
      refresh_creator_bindings(creator)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-command-digest"))
      end
      assert_equal "workflow-creator execution receipt identity is invalid", error.message
    end
  end

  def test_creator_nonpassing_schema_is_typed_bounded_and_secret_safe
    detail = "provider failed with exact-fixture-secret and sk-ant-abcdefghijklmnopqrstuvwxyz"
    row = HiveLiveAgentProof::WorkflowCreatorContract.failure(
      candidate_sha: SHA,
      phase: "preflight",
      reason: "provider_unavailable",
      detail: detail,
      exact_secrets: [ "exact-fixture-secret" ]
    )

    assert_equal %w[
      candidate_sha detail execution_kind model_loop phase platform reason
      result schema schema_version secret_scan
    ], row.keys.sort
    assert_equal "failed", row.fetch("result")
    assert_equal "unavailable", row.fetch("execution_kind")
    assert_equal "not_started", row.fetch("model_loop")
    assert_equal 2, row.fetch("detail").scan("[REDACTED]").length
    refute_includes row.fetch("detail"), "exact-fixture-secret"
    refute_includes row.fetch("detail"), "sk-ant-"
    assert_same row, HiveLiveAgentProof::WorkflowCreatorContract.validate_nonpassing!(row)

    unresolved = HiveLiveAgentProof::WorkflowCreatorContract.failure(
      candidate_sha: "unknown", phase: "preflight", reason: "not_started",
      detail: "x" * 1_500
    )
    assert_equal "unresolved", unresolved.fetch("candidate_sha")
    assert_operator unresolved.fetch("detail").bytesize, :<=, 1_000

    no_detail = HiveLiveAgentProof::WorkflowCreatorContract.failure(
      candidate_sha: SHA, phase: "preflight", reason: "not_started"
    )
    assert_nil no_detail.fetch("detail")
    assert_same no_detail,
                HiveLiveAgentProof::WorkflowCreatorContract.validate_nonpassing!(no_detail)

    [
      ->(value) { value["unexpected"] = true },
      ->(value) { value["result"] = "passed" },
      ->(value) { value["candidate_sha"] = ("1" * 40).to_i },
      ->(value) { value["phase"] = :preflight },
      ->(value) { value["phase"] = "not-valid!" },
      ->(value) { value["model_loop"] = "executed" },
      ->(value) { value["detail"] = "sk-ant-abcdefghijklmnopqrstuvwxyz" },
      ->(value) { value["detail"] = "\xFF".b }
    ].each do |mutation|
      invalid = JSON.parse(JSON.generate(row))
      mutation.call(invalid)
      assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreatorContract.validate_nonpassing!(invalid)
      end
    end
  end

  def test_creator_contract_boundaries_normalize_low_level_failures
    error = assert_raises(HiveLiveAgentProof::Error) do
      HiveLiveAgentProof.canonical_json("\xFF".b)
    end
    assert_match(/cannot canonicalize JSON/, error.message)
    refute HiveLiveAgentProof.safe_relative_path?("invalid\0path")

    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      creator = prepare_creator_evidence(dir, artifacts)
      manifest = JSON.parse(File.read(File.join(artifacts, "artifact-manifest.json")))
      row = JSON.parse(File.read(File.join(creator, "openclaw-workflow-creator.json")))
      receipt = JSON.parse(File.read(File.join(creator, "execution-receipt.json")))

      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreatorContract.validate!(
          row: row, manifest: manifest, candidate_sha: SHA, bundle_records: nil
        )
      end
      assert_equal "workflow-creator contract is invalid", error.message

      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreatorExecutionContract.validate!(
          receipt: receipt, row: row, candidate_sha: SHA,
          installation_records: nil, receipt_sha256: "d" * 64
        )
      end
      assert_equal "workflow-creator execution receipt is invalid", error.message

      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreatorBundle.validate_source!(
          directory: creator, manifest: nil, candidate_sha: SHA
        )
      end
      assert_equal "workflow-creator bundle contract is invalid", error.message

      File.binwrite(File.join(creator, "execution-receipt.json"), "{invalid")
      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreatorBundle.validate_source!(
          directory: creator, manifest: manifest, candidate_sha: SHA
        )
      end
      assert_equal "workflow-creator bundle JSON is invalid", error.message
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
    File.chmod(0o700, evidence)
    created_files = HiveLiveAgentProof::WORKFLOW_CREATOR_FILES.map do |path|
      { "path" => path, "sha256" => Digest::SHA256.hexdigest(path), "size" => 10 }
    end
    candidate_package_name, candidate_package = manifest.fetch("files").find do |name, _record|
      name.match?(/\Ahive-cli-[0-9].*\.gem\z/)
    end
    candidate_members = installed_members(
      %w[audit_gateway executable interpreter_or_launcher lock package],
      package_path: "packages/#{candidate_package_name}",
      package_record: candidate_package
    )
    openclaw_members = installed_members(
      %w[executable interpreter_or_launcher lock package],
      package_path: "packages/openclaw.tgz"
    )
    installed = {
      "candidate-installed-manifest.json" =>
        installed_manifest("candidate", Hive::VERSION, candidate_members),
      "openclaw-installed-manifest.json" =>
        installed_manifest("openclaw", "fixture-openclaw", openclaw_members)
    }
    installed.each do |name, document|
      HiveLiveAgentProof.write_json(File.join(evidence, name), document)
    end
    installed_records = %w[
      candidate-installed-manifest.json openclaw-installed-manifest.json
    ].each_with_index.map do |name, index|
      bundle_record(%w[candidate_installation openclaw_installation].fetch(index), name, evidence)
    end
    executed_instruction = created_files.find do |record|
      record["path"] == HiveLiveAgentProof::WORKFLOW_CREATOR_EXECUTED_INSTRUCTION
    end
    execution_receipt = {
      "schema" => "hive-live-workflow-creator-execution-receipt",
      "schema_version" => 1,
      "candidate_sha" => SHA,
      "result" => "passed",
      "execution_plan" => "hive-live-workflow-creator-execution-plan/v1",
      "classification" => {
        "execution_kind" => "authenticated_openclaw",
        "model_loop" => "executed"
      },
      "installed_manifests" => installed_records,
      "prompt_sha256" => [
        Digest::SHA256.hexdigest(HiveLiveAgentProof::WORKFLOW_CREATOR_PROMPT),
        Digest::SHA256.hexdigest(HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_PROMPT)
      ],
      "hive_commands_sha256" =>
        Digest::SHA256.hexdigest(canonical_json(HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS)),
      "authored_instruction" => executed_instruction,
      "executed_instruction" => executed_instruction,
      "external_actions" => [],
      "containment" => { "status" => "passed" },
      "teardown" => { "status" => "passed" },
      "cleanup" => { "status" => "passed" },
      "secret_scan" => {
        "status" => "passed", "scanner" => "hive-live-agent-proof/v1"
      }
    }
    HiveLiveAgentProof.write_json(
      File.join(evidence, "execution-receipt.json"), execution_receipt
    )
    execution_record = bundle_record(
      "execution_receipt", "execution-receipt.json", evidence
    )
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
      "native_activation" => HiveLiveAgentProof::WORKFLOW_CREATOR_NATIVE_ACTIVATION,
      "hive_commands" => HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS,
      "created_files" => created_files,
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
      "secret_scan" => {
        "status" => "passed", "scanner" => "hive-live-agent-proof/v1"
      },
      "execution_kind" => "authenticated_openclaw",
      "model_loop" => "executed",
      "executed_instruction" => executed_instruction,
      "evidence_bundle" => [ *installed_records, execution_record ],
      "containment" => {
        "status" => "passed", "receipt_sha256" => execution_record.fetch("sha256")
      },
      "teardown" => {
        "status" => "passed", "receipt_sha256" => execution_record.fetch("sha256")
      },
      "cleanup" => {
        "status" => "passed", "receipt_sha256" => execution_record.fetch("sha256")
      }
    }
    HiveLiveAgentProof.write_json(File.join(evidence, "openclaw-workflow-creator.json"), row)
    evidence
  end

  def installed_members(roles, package_path:, package_record: nil)
    roles.map do |role|
      path = role == "package" ? package_path : "#{role}/fixture"
      {
        "role" => role,
        "path" => path,
        "sha256" => package_record&.fetch("sha256") || Digest::SHA256.hexdigest(path),
        "size" => package_record&.fetch("size") || path.bytesize
      }
    end
  end

  def installed_manifest(kind, version, members)
    {
      "schema" => "hive-live-workflow-creator-installed-manifest",
      "schema_version" => 1,
      "candidate_sha" => SHA,
      "kind" => kind,
      "version" => version,
      "closure_sha256" => Digest::SHA256.hexdigest(canonical_json(members)),
      "members" => members,
      "total_size" => members.sum { |member| member.fetch("size") },
      "secret_scan" => {
        "status" => "passed", "scanner" => "hive-live-agent-proof/v1"
      }
    }
  end

  def bundle_record(kind, name, directory)
    path = File.join(directory, name)
    {
      "kind" => kind,
      "path" => name,
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "size" => File.size(path)
    }
  end

  def refresh_creator_bindings(directory)
    installed_records = %w[
      candidate-installed-manifest.json openclaw-installed-manifest.json
    ].each_with_index.map do |name, index|
      bundle_record(%w[candidate_installation openclaw_installation].fetch(index), name, directory)
    end
    receipt_path = File.join(directory, "execution-receipt.json")
    receipt = JSON.parse(File.read(receipt_path))
    receipt["installed_manifests"] = installed_records
    HiveLiveAgentProof.write_json(receipt_path, receipt)
    receipt_record = bundle_record("execution_receipt", "execution-receipt.json", directory)
    row_path = File.join(directory, "openclaw-workflow-creator.json")
    row = JSON.parse(File.read(row_path))
    row["evidence_bundle"] = [ *installed_records, receipt_record ]
    %w[containment teardown cleanup].each do |field|
      row[field] = {
        "status" => "passed", "receipt_sha256" => receipt_record.fetch("sha256")
      }
    end
    HiveLiveAgentProof.write_json(row_path, row)
  end

  def canonical_json(value)
    "#{JSON.pretty_generate(value)}\n"
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
