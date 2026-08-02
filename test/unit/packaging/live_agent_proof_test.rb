require "test_helper"
require "hive/agent_skills/canonical_skill"
require "timeout"
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
      assert_equal canonical_json(row), File.binread(path)
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
        write_creator_json(path, row) if File.exist?(path)

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
        write_creator_json(retained_path, retained)
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
      write_creator_json(row_path, row)

      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-task"))
      end
      assert_includes error.message, "unauthorized side effect"

      creator_evidence = prepare_creator_evidence(dir, artifacts)
      row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(row_path))
      row["validation"]["stages"] << "publish"
      write_creator_json(row_path, row)
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
        write_creator_json(path, row)

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
      package = installed.dig("required_roles", "package")
      package["sha256"] = "d" * 64
      installed.fetch("inventory").find { |record| record["path"] == package["path"] }["sha256"] = "d" * 64
      installed["closure_sha256"] = Digest::SHA256.hexdigest(
        canonical_json(installed.slice("required_roles", "inventory"))
      )
      write_creator_json(path, installed)
      refresh_creator_bindings(creator)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-candidate-package"))
      end
      assert_equal "workflow-creator candidate installed package does not match the release artifact",
                   error.message

      creator = prepare_creator_evidence(File.join(dir, "openclaw-closure"), artifacts)
      path = File.join(creator, "openclaw-installed-manifest.json")
      installed = JSON.parse(File.read(path))
      installed.fetch("inventory")[1]["path"] = installed.fetch("inventory")[0]["path"]
      installed["closure_sha256"] = Digest::SHA256.hexdigest(
        canonical_json(installed.slice("required_roles", "inventory"))
      )
      write_creator_json(path, installed)
      refresh_creator_bindings(creator)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-openclaw-closure"))
      end
      assert_equal "workflow-creator openclaw installed inventory order is invalid",
                   error.message

      creator = prepare_creator_evidence(File.join(dir, "command-argv"), artifacts)
      path = File.join(creator, "execution-receipt.json")
      receipt = JSON.parse(File.read(path))
      receipt.fetch("commands").first["argv"] = [ "doctor" ]
      write_creator_json(path, receipt)
      refresh_creator_bindings(creator)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof-command-argv"))
      end
      assert_equal "workflow-creator execution command receipts are invalid", error.message
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
          installation_records: nil, receipt_sha256: "d" * 64,
          candidate_installation: nil, openclaw_installation: nil
        )
      end
      assert_equal "workflow-creator execution receipt identity is invalid", error.message

      installed_records = %w[
        candidate-installed-manifest.json openclaw-installed-manifest.json
      ].each_with_index.map do |name, index|
        bundle_record(%w[candidate_installation openclaw_installation].fetch(index), name, creator)
      end
      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreatorExecutionContract.validate!(
          receipt: receipt, row: row, candidate_sha: SHA,
          installation_records: installed_records,
          receipt_sha256: bundle_record("execution_receipt", "execution-receipt.json", creator).fetch("sha256"),
          candidate_installation: {},
          openclaw_installation: JSON.parse(File.read(File.join(creator, "openclaw-installed-manifest.json")))
        )
      end
      assert_equal "workflow-creator execution receipt is invalid", error.message

      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreator.validate_source!(
          directory: creator, manifest: nil, candidate_sha: SHA
        )
      end
      assert_equal "workflow-creator bundle contract is invalid", error.message

      File.binwrite(File.join(creator, "execution-receipt.json"), "{invalid")
      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreator.validate_source!(
          directory: creator, manifest: manifest, candidate_sha: SHA
        )
      end
      assert_equal "workflow-creator bundle JSON is invalid", error.message
    end
  end

  def test_creator_canonical_json_is_recursive_and_raw_key_order_fails_closed
    left = { "z" => { "b" => 2, "a" => 1 }, "a" => [ { "d" => 4, "c" => 3 } ] }
    right = { "a" => [ { "c" => 3, "d" => 4 } ], "z" => { "a" => 1, "b" => 2 } }
    assert_equal canonical_json(left), canonical_json(right)
    assert_raises(HiveLiveAgentProof::Error) { canonical_json({ invalid: true }) }

    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      {
        "top-level" => ->(row) { row.to_a.reverse.to_h },
        "nested" => lambda do |row|
          row["skill"] = row.fetch("skill").to_a.reverse.to_h
          row
        end
      }.each do |label, reorder|
        creator = prepare_creator_evidence(File.join(dir, label), artifacts)
        path = File.join(creator, "openclaw-workflow-creator.json")
        document = reorder.call(JSON.parse(File.read(path)))
        File.binwrite(path, "#{JSON.pretty_generate(document)}\n")
        File.chmod(0o600, path)

        error = assert_raises(HiveLiveAgentProof::Error, label) do
          attest(artifacts, evidence, creator, File.join(dir, "proof-#{label}"))
        end
        assert_includes error.message, "not canonical JSON", label
      end
    end
  end

  def test_creator_rejects_reordered_claims_and_float_substitutions
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      cases = {
        "created-files-order" => [ "openclaw-workflow-creator.json", ->(doc) { doc["created_files"].reverse! } ],
        "created-files-missing" => [ "openclaw-workflow-creator.json", ->(doc) { doc["created_files"].pop } ],
        "validation-type" => [ "openclaw-workflow-creator.json", ->(doc) { doc["validation"] = nil } ],
        "secret-status" => [ "openclaw-workflow-creator.json", ->(doc) { doc["secret_scan"]["status"] = "failed" } ],
        "cleanup-status" => [ "openclaw-workflow-creator.json", ->(doc) { doc["cleanup"]["status"] = "failed" } ],
        "evidence-schema-float" => [ "openclaw-workflow-creator.json", ->(doc) { doc["schema_version"] = 1.0 } ],
        "task-count-float" => [ "openclaw-workflow-creator.json", ->(doc) { doc["task_count"] = 1.0 } ],
        "run-count-float" => [ "openclaw-workflow-creator.json", ->(doc) { doc["task"]["run_count"] = 1.0 } ],
        "created-size-float" => [ "openclaw-workflow-creator.json", ->(doc) { doc["created_files"][0]["size"] = 10.0 } ],
        "installed-schema-float" => [ "candidate-installed-manifest.json", ->(doc) { doc["schema_version"] = 1.0 } ],
        "installed-member-float" => [ "candidate-installed-manifest.json", ->(doc) { doc["inventory"][0]["size"] = 1.0 } ],
        "installed-total-float" => [ "candidate-installed-manifest.json", ->(doc) { doc["total_size"] = doc["total_size"].to_f } ],
        "receipt-schema-float" => [ "execution-receipt.json", ->(doc) { doc["schema_version"] = 1.0 } ],
        "command-position-float" => [ "execution-receipt.json", ->(doc) { doc["commands"][0]["position"] = 1.0 } ],
        "archive-size-float" => [ "execution-receipt.json", ->(doc) { doc["archive_admissions"][0]["artifact_size"] = 1.0 } ],
        "capture-limit-float" => [ "execution-receipt.json", ->(doc) { doc["commands"][0]["capture"]["limit_bytes"] = 4_096.0 } ],
        "gateway-size-float" => [ "execution-receipt.json", ->(doc) { doc["gateway"]["identity"]["size"] = doc["gateway"]["identity"]["size"].to_f } ],
        "authored-size-float" => [ "execution-receipt.json", ->(doc) { doc["authored_instruction"]["size"] = doc["authored_instruction"]["size"].to_f } ],
        "executed-size-float" => [ "execution-receipt.json", ->(doc) { doc["executed_instruction"]["size"] = doc["executed_instruction"]["size"].to_f } ],
        "cleanup-inode-float" => [ "execution-receipt.json", ->(doc) { doc["cleanup"]["targets"][0]["inode"] = 2.0 } ],
        "descendants-float" => [ "execution-receipt.json", ->(doc) { doc["teardown"]["remaining_descendants"] = 0.0 } ]
      }
      cases.each do |label, (name, mutate)|
        creator = prepare_creator_evidence(File.join(dir, label), artifacts)
        path = File.join(creator, name)
        document = JSON.parse(File.read(path))
        mutate.call(document)
        write_creator_json(path, document)
        if name.end_with?("installed-manifest.json")
          refresh_creator_bindings(creator)
        elsif name == "execution-receipt.json"
          refresh_primary_binding(creator)
        end

        assert_raises(HiveLiveAgentProof::Error, label) do
          attest(artifacts, evidence, creator, File.join(dir, "proof-#{label}"))
        end
      end
    end
  end

  def test_creator_installed_manifests_bind_complete_inventory_roles_and_version
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      cases = {
        "candidate-version" => ->(doc) { doc["version"] = "9.9.9" },
        "inventory-order" => ->(doc) { doc["inventory"].reverse! },
        "inventory-duplicate" => ->(doc) { doc["inventory"] << doc["inventory"].last.dup },
        "unclosed-extra" => lambda do |doc|
          doc["inventory"] << {
            "path" => "zz/unclaimed", "sha256" => "d" * 64, "size" => 1
          }
          doc["total_size"] += 1
        end,
        "duplicate-role" => ->(doc) { doc["required_roles"]["executable"] = doc["required_roles"]["lock"] }
      }
      cases.each do |label, mutate|
        creator = prepare_creator_evidence(File.join(dir, label), artifacts)
        path = File.join(creator, "candidate-installed-manifest.json")
        document = JSON.parse(File.read(path))
        mutate.call(document)
        write_creator_json(path, document)
        refresh_creator_bindings(creator)

        assert_raises(HiveLiveAgentProof::Error, label) do
          attest(artifacts, evidence, creator, File.join(dir, "proof-#{label}"))
        end
      end
    end
  end

  def test_creator_execution_receipt_is_a_closed_supervised_transaction
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      cases = {
        "extra-field" => ->(doc) { doc["unexpected"] = true },
        "missing-command" => ->(doc) { doc["commands"].pop },
        "command-order" => ->(doc) { doc["commands"][0], doc["commands"][1] = doc["commands"][1], doc["commands"][0] },
        "command-argv" => ->(doc) { doc["commands"][5]["argv"] = [ "doctor" ] },
        "outer-role-order" => ->(doc) { doc["outer_processes"].reverse! },
        "outer-prompt" => ->(doc) { doc["outer_processes"][0]["prompt_sha256"] = "d" * 64 },
        "outer-argv-alias" => ->(doc) { doc["outer_processes"][1]["argv_sha256"] = doc["outer_processes"][0]["argv_sha256"] },
        "duplicate-label" => ->(doc) { doc["outer_processes"][0]["label"] = doc["commands"][0]["attempt_label"] },
        "gateway" => ->(doc) { doc["gateway"]["identity"]["sha256"] = "d" * 64 },
        "archive-order" => ->(doc) { doc["archive_admissions"].reverse! },
        "archive-policy" => ->(doc) { doc["archive_admissions"][0]["policy_sha256"] = "d" * 64 },
        "capture-bound" => ->(doc) { doc["commands"][0]["capture"]["stdout_bytes"] = 4_097 },
        "teardown-order" => lambda do |doc|
          doc["commands"][0]["teardown"]["kill_sent"] = true
          doc["commands"][0]["teardown"]["term_sent"] = false
        end,
        "run-labels" => ->(doc) { doc["run"]["expected_labels"].reverse! },
        "secret-material" => lambda do |doc|
          doc["run"]["correlation_id"] = "sk-ant-abcdefghijklmnopqrstuvwxyz"
          doc["containment"]["owner_correlation_id"] = "sk-ant-abcdefghijklmnopqrstuvwxyz"
        end,
        "containment" => ->(doc) { doc["containment"]["established_before_launch"] = false },
        "teardown-receipts" => ->(doc) { doc["teardown"]["receipt_labels"].pop },
        "cleanup-custody" => ->(doc) { doc["cleanup"]["targets"][0]["identity_matched"] = false },
        "authored-binding" => ->(doc) { doc["authored_instruction"]["sha256"] = "d" * 64 }
      }
      cases.each do |label, mutate|
        creator = prepare_creator_evidence(File.join(dir, label), artifacts)
        path = File.join(creator, "execution-receipt.json")
        document = JSON.parse(File.read(path))
        mutate.call(document)
        write_creator_json(path, document)
        refresh_primary_binding(creator)

        assert_raises(HiveLiveAgentProof::Error, label) do
          attest(artifacts, evidence, creator, File.join(dir, "proof-#{label}"))
        end
      end
    end
  end

  def test_creator_facade_and_custody_fail_closed_without_attested_or_regular_evidence
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator = prepare_creator_evidence(dir, artifacts)
      manifest = JSON.parse(File.read(File.join(artifacts, "artifact-manifest.json")))
      snapshot = HiveLiveAgentProof::WorkflowCreator.validate_source!(
        directory: creator, manifest: manifest, candidate_sha: SHA
      )
      assert_instance_of HiveLiveAgentProof::WorkflowCreator::Snapshot, snapshot
      ambiguous = JSON.parse(JSON.generate(manifest))
      package_name, package = ambiguous.fetch("files").find do |name, _record|
        name.match?(/\Ahive-cli-[0-9].*\.gem\z/)
      end
      ambiguous.fetch("files")["hive-cli-9.9.9.gem"] = package.merge("kind" => "gem")
      error = assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreator.validate_source!(
          directory: creator, manifest: ambiguous, candidate_sha: SHA
        )
      end
      assert_includes error.message, "exactly one package"
      assert_match(/hive-cli-/, package_name)
      failure = HiveLiveAgentProof::WorkflowCreator.failure(
        candidate_sha: SHA, phase: "preflight", reason: "not_started"
      )
      assert_same failure, HiveLiveAgentProof::WorkflowCreator.validate_nonpassing!(failure)

      if File.respond_to?(:mkfifo)
        fifo = prepare_creator_evidence(File.join(dir, "fifo"), artifacts)
        receipt = File.join(fifo, "execution-receipt.json")
        FileUtils.rm_f(receipt)
        File.mkfifo(receipt, 0o600)
        error = Timeout.timeout(2) do
          assert_raises(HiveLiveAgentProof::Error) do
            attest(artifacts, evidence, fifo, File.join(dir, "proof-fifo"))
          end
        end
        assert_includes error.message, "private regular file"
      end

      oversized = prepare_creator_evidence(File.join(dir, "source-limit"), artifacts)
      13.times { |index| File.write(File.join(oversized, "extra-#{index}.json"), "{}") }
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, oversized, File.join(dir, "proof-source-limit"))
      end
      assert_includes error.message, "inventory exceeds the limit"

      source_proof = File.join(dir, "source-proof")
      result = attest(artifacts, evidence, creator, source_proof)
      %w[missing nil].each do |label|
        proof = File.join(dir, "proof-attestation-#{label}")
        FileUtils.cp_r(source_proof, proof)
        path = File.join(proof, "attestation.json")
        attestation = JSON.parse(File.read(path))
        label == "missing" ? attestation.delete("workflow_creator") : attestation["workflow_creator"] = nil
        HiveLiveAgentProof.write_json(path, attestation)
        error = assert_raises(HiveLiveAgentProof::Error, label) do
          verifier(proof, HiveLiveAgentProof.sha256(path)).call
        end
        assert_includes error.message, "attested evidence is missing", label
      end

      retained = File.join(source_proof, "evidence")
      index = 0
      while Dir.children(retained).length <= 16
        File.write(File.join(retained, "retained-extra-#{index}"), "extra")
        index += 1
      end
      error = assert_raises(HiveLiveAgentProof::Error) do
        verifier(source_proof, result.fetch("sha256")).call
      end
      assert_includes error.message, "inventory exceeds the limit"
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
    assert_empty HiveLiveAgentProof.secret_findings("safe", exact_secrets: [ "", "absent" ])
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
    candidate_roles, candidate_inventory = installed_inventory(
      %w[audit_gateway executable interpreter_or_launcher lock package],
      package_path: "packages/#{candidate_package_name}",
      package_record: candidate_package
    )
    openclaw_roles, openclaw_inventory = installed_inventory(
      %w[executable interpreter_or_launcher lock package],
      package_path: "packages/openclaw.tgz"
    )
    installed = {
      "candidate-installed-manifest.json" =>
        installed_manifest("candidate", Hive::VERSION, candidate_roles, candidate_inventory),
      "openclaw-installed-manifest.json" =>
        installed_manifest("openclaw", "fixture-openclaw", openclaw_roles, openclaw_inventory)
    }
    installed.each do |name, document|
      write_creator_json(File.join(evidence, name), document)
    end
    installed_records = %w[
      candidate-installed-manifest.json openclaw-installed-manifest.json
    ].each_with_index.map do |name, index|
      bundle_record(%w[candidate_installation openclaw_installation].fetch(index), name, evidence)
    end
    executed_instruction = created_files.find do |record|
      record["path"] == HiveLiveAgentProof::WORKFLOW_CREATOR_EXECUTED_INSTRUCTION
    end
    execution_receipt = execution_receipt(
      installed_records: installed_records, installed: installed,
      executed_instruction: executed_instruction
    )
    write_creator_json(File.join(evidence, "execution-receipt.json"), execution_receipt)
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
    write_creator_json(File.join(evidence, "openclaw-workflow-creator.json"), row)
    evidence
  end

  def installed_inventory(roles, package_path:, package_record: nil)
    required = roles.to_h do |role|
      path = role == "package" ? package_path : "#{role}/fixture"
      record = {
        "path" => path,
        "sha256" => package_record&.fetch("sha256") || Digest::SHA256.hexdigest(path),
        "size" => package_record&.fetch("size") || path.bytesize
      }
      [ role, record ]
    end
    dependency = {
      "path" => "runtime/dependency.rb",
      "sha256" => Digest::SHA256.hexdigest("runtime/dependency.rb"),
      "size" => 21
    }
    [ required, [ *required.values, dependency ].sort_by { |record| record.fetch("path") } ]
  end

  def installed_manifest(kind, version, required_roles, inventory)
    closure = { "required_roles" => required_roles, "inventory" => inventory }
    {
      "schema" => "hive-live-workflow-creator-installed-manifest",
      "schema_version" => 1,
      "candidate_sha" => SHA,
      "kind" => kind,
      "version" => version,
      "required_roles" => required_roles,
      "inventory" => inventory,
      "closure_sha256" => Digest::SHA256.hexdigest(canonical_json(closure)),
      "total_size" => inventory.sum { |member| member.fetch("size") },
      "secret_scan" => {
        "status" => "passed", "scanner" => "hive-live-agent-proof/v1"
      }
    }
  end

  def execution_receipt(installed_records:, installed:, executed_instruction:)
    command_labels = HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.each_index.map do |index|
      format("command-%02d", index + 1)
    end
    commands = HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.each_with_index.map do |argv, index|
      process_receipt("attempt_label" => command_labels.fetch(index)).merge(
        "position" => index + 1, "argv" => argv
      )
    end
    outer = HiveLiveAgentProof::WORKFLOW_CREATOR_OUTER_ROLES.each_with_index.map do |identity, index|
      process_receipt("label" => %w[outer-workflow-creator outer-authorized-work].fetch(index)).merge(
        identity, "argv_sha256" => Digest::SHA256.hexdigest("outer-argv-#{index}")
      )
    end
    labels = command_labels + outer.map { |process| process.fetch("label") }
    correlation = "workflow-creator-proof-run"
    packages = installed.values.map { |document| document.dig("required_roles", "package") }
    archives = packages.each_with_index.map do |package, index|
      {
        "label" => HiveLiveAgentProof::WORKFLOW_CREATOR_ARCHIVE_LABELS.fetch(index),
        "artifact_sha256" => package.fetch("sha256"), "artifact_size" => package.fetch("size"),
        "policy_sha256" => HiveLiveAgentProof::WORKFLOW_CREATOR_ARCHIVE_POLICY_SHA256,
        "entry_count" => 5, "uncompressed_bytes" => 1_024, "status" => "passed"
      }
    end
    {
      "schema" => HiveLiveAgentProof::WORKFLOW_CREATOR_EXECUTION_SCHEMA,
      "schema_version" => 1, "candidate_sha" => SHA, "result" => "passed",
      "execution_plan" => HiveLiveAgentProof::WORKFLOW_CREATOR_EXECUTION_PLAN,
      "classification" => {
        "outer" => HiveLiveAgentProof::WORKFLOW_CREATOR_CLASSIFICATION,
        "nested_stage" => {
          "execution_kind" => "deterministic_fixture", "model_loop" => "not_exercised"
        }
      },
      "installed_manifests" => installed_records,
      "run" => { "correlation_id" => correlation, "expected_labels" => labels },
      "gateway" => {
        "identity" => installed.fetch("candidate-installed-manifest.json").dig("required_roles", "audit_gateway"),
        "command_labels" => command_labels, "status" => "passed"
      },
      "archive_admissions" => archives, "commands" => commands, "outer_processes" => outer,
      "authored_instruction" => executed_instruction, "executed_instruction" => executed_instruction,
      "external_actions" => [],
      "containment" => {
        "status" => "passed", "mechanism" => "supervised-process-tree",
        "established_before_launch" => true, "owner_correlation_id" => correlation,
        "root_loss_behavior" => "fail-closed"
      },
      "teardown" => {
        "status" => "passed", "expected_labels" => labels, "receipt_labels" => labels,
        "outer_root_reaped" => true, "remaining_descendants" => 0
      },
      "cleanup" => {
        "status" => "passed",
        "targets" => [
          {
            "label" => "proof-workspace", "path_sha256" => Digest::SHA256.hexdigest("workspace"),
            "device" => 1, "inode" => 2, "created_by_run" => true,
            "identity_matched" => true, "removed" => true
          }
        ]
      },
      "secret_scan" => { "status" => "passed", "scanner" => "hive-live-agent-proof/v1" }
    }
  end

  def process_receipt(label)
    label.merge(
      "exit_code" => 0, "signal" => nil, "completed" => true,
      "capture" => {
        "limit_bytes" => 4_096, "stdout_bytes" => 0, "stderr_bytes" => 0,
        "stdout_sha256" => Digest::SHA256.hexdigest(""),
        "stderr_sha256" => Digest::SHA256.hexdigest(""),
        "stdout_truncated" => false, "stderr_truncated" => false,
        "secret_scan" => { "status" => "passed", "scanner" => "hive-live-agent-proof/v1" }
      },
      "teardown" => {
        "status" => "passed", "term_sent" => false, "kill_sent" => false,
        "reaped" => true, "descendants" => "none", "owner_complete" => true
      }
    )
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
    candidate = JSON.parse(File.read(File.join(directory, "candidate-installed-manifest.json")))
    openclaw = JSON.parse(File.read(File.join(directory, "openclaw-installed-manifest.json")))
    receipt["gateway"]["identity"] = candidate.dig("required_roles", "audit_gateway")
    [ candidate, openclaw ].each_with_index do |installation, index|
      package = installation.dig("required_roles", "package")
      receipt["archive_admissions"][index]["artifact_sha256"] = package.fetch("sha256")
      receipt["archive_admissions"][index]["artifact_size"] = package.fetch("size")
    end
    write_creator_json(receipt_path, receipt)
    refresh_primary_binding(directory)
  end

  def refresh_primary_binding(directory)
    installed_records = %w[
      candidate-installed-manifest.json openclaw-installed-manifest.json
    ].each_with_index.map do |name, index|
      bundle_record(%w[candidate_installation openclaw_installation].fetch(index), name, directory)
    end
    receipt_record = bundle_record("execution_receipt", "execution-receipt.json", directory)
    row_path = File.join(directory, "openclaw-workflow-creator.json")
    row = JSON.parse(File.read(row_path))
    row["evidence_bundle"] = [ *installed_records, receipt_record ]
    %w[containment teardown cleanup].each do |field|
      row[field] = {
        "status" => "passed", "receipt_sha256" => receipt_record.fetch("sha256")
      }
    end
    write_creator_json(row_path, row)
  end

  def canonical_json(value)
    HiveLiveAgentProof.canonical_json(value)
  end

  def write_creator_json(path, value)
    File.binwrite(path, canonical_json(value))
    File.chmod(0o600, path)
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
