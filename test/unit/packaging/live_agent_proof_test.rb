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
      FileUtils.rm_rf(creator_evidence)

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
      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS, creator.fetch("hive_commands")
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

  def test_attestor_and_verifier_share_authored_execution_cross_binding
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator = prepare_creator_evidence(dir, artifacts)
      primary = File.join(creator, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(primary))
      row["executed_instruction"]["sha256"] = "0" * 64
      HiveLiveAgentProof.write_json(primary, row)

      attestor_error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "rejected-proof"))
      end

      creator = prepare_creator_evidence(File.join(dir, "verifier"), artifacts)
      proof = File.join(dir, "proof")
      result = attest(artifacts, evidence, creator, proof)
      attestation_path = File.join(proof, "attestation.json")
      attestation = JSON.parse(File.read(attestation_path))
      attestation["workflow_creator"]["executed_instruction"]["sha256"] = "0" * 64
      HiveLiveAgentProof.write_json(attestation_path, attestation)
      retained = File.join(
        proof, "evidence", "workflow-creator",
        "openclaw-workflow-creator.json"
      )
      retained_row = JSON.parse(File.read(retained))
      retained_row["executed_instruction"]["sha256"] = "0" * 64
      HiveLiveAgentProof.write_json(retained, retained_row)
      verifier_error = assert_raises(HiveLiveAgentProof::Error) do
        verifier(proof, HiveLiveAgentProof.sha256(attestation_path)).call
      end

      assert_equal(
        "workflow-creator authored and executed instructions do not match",
        attestor_error.message
      )
      assert_equal attestor_error.message, verifier_error.message
      refute_equal result.fetch("sha256"), HiveLiveAgentProof.sha256(attestation_path)
    end
  end

  def test_attestor_rejects_missing_extra_reordered_duplicate_unsafe_or_mismatched_bundle_entries
    mutations = {
      "missing" => lambda do |root, _row|
        FileUtils.rm_f(File.join(root, "candidate-installed-manifest.json"))
      end,
      "extra" => lambda do |root, _row|
        HiveLiveAgentProof.write_json(File.join(root, "extra.json"), {})
      end,
      "reordered" => lambda do |_root, row|
        row["evidence_bundle"][0], row["evidence_bundle"][1] =
          row["evidence_bundle"][1], row["evidence_bundle"][0]
      end,
      "duplicate" => lambda do |_root, row|
        row["evidence_bundle"][1] = row["evidence_bundle"][0].dup
      end,
      "digest" => lambda do |_root, row|
        row["evidence_bundle"][0]["sha256"] = "0" * 64
      end,
      "symlink" => lambda do |root, _row|
        path = File.join(root, "candidate-installed-manifest.json")
        outside = File.join(File.dirname(root), "outside-manifest.json")
        FileUtils.mv(path, outside)
        File.symlink(outside, path)
      end,
      "oversized" => lambda do |_root, row|
        row["evidence_bundle"][0]["size"] =
          HiveLiveAgentProof::WorkflowCreatorBundle::MAX_FILE_BYTES + 1
      end
    }

    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      mutations.each do |name, mutate|
        creator = prepare_creator_evidence(File.join(dir, name), artifacts)
        primary = File.join(creator, "openclaw-workflow-creator.json")
        row = JSON.parse(File.read(primary))
        mutate.call(creator, row)
        HiveLiveAgentProof.write_json(primary, row)

        assert_raises(HiveLiveAgentProof::Error, name) do
          attest(
            artifacts, evidence, creator,
            File.join(dir, "proof-bundle-#{name}")
          )
        end
      end
    end
  end

  def test_attestor_admits_primary_through_bounded_no_follow_reader
    mutations = {
      "symlink" => lambda do |root|
        path = File.join(root, "openclaw-workflow-creator.json")
        outside = File.join(File.dirname(root), "outside-primary.json")
        FileUtils.mv(path, outside)
        File.symlink(outside, path)
      end,
      "hard-link" => lambda do |root|
        path = File.join(root, "openclaw-workflow-creator.json")
        outside = File.join(File.dirname(root), "outside-primary-hard-link.json")
        File.link(path, outside)
      end,
      "oversized" => lambda do |root|
        File.binwrite(
          File.join(root, "openclaw-workflow-creator.json"),
          "x" * (HiveLiveAgentProof::WorkflowCreatorBundle::MAX_FILE_BYTES + 1)
        )
      end
    }

    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      mutations.each do |name, mutate|
        creator = prepare_creator_evidence(File.join(dir, name), artifacts)
        mutate.call(creator)

        error = assert_raises(HiveLiveAgentProof::Error, name) do
          attest(
            artifacts, evidence, creator,
            File.join(dir, "proof-primary-#{name}")
          )
        end
        assert_includes error.message, "unsafe or oversized"
      end
    end
  end

  def test_attestor_rejects_invalid_installed_inventory_boundaries
    max_entries =
      HiveLiveAgentProof::WorkflowCreatorBundle::MAX_INVENTORY_ENTRIES
    max_file =
      HiveLiveAgentProof::WorkflowCreatorBundle::MAX_INSTALLED_FILE_BYTES
    mutations = {
      "empty" => [],
      "over-count" => Array.new(max_entries + 1) do |index|
        inventory_record(format("files/%04d", index), size: 1)
      end,
      "oversized-file" => [
        inventory_record("bin/hive", size: max_file + 1)
      ],
      "oversized-total" => Array.new(5) do |index|
        inventory_record(format("files/%04d", index), size: max_file)
      end,
      "dot-path" => [ inventory_record(".", size: 1) ],
      "nul-path" => [ inventory_record("bin/hi\0ve", size: 1) ]
    }

    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      mutations.each do |name, inventory|
        creator = prepare_creator_evidence(File.join(dir, name), artifacts)
        installed_path =
          File.join(creator, "candidate-installed-manifest.json")
        installed = JSON.parse(File.read(installed_path))
        installed["inventory"] = inventory
        HiveLiveAgentProof.write_json(installed_path, installed)
        refresh_creator_bundle_record!(
          creator,
          "candidate-installed-manifest.json"
        )

        assert_raises(HiveLiveAgentProof::Error, name) do
          attest(
            artifacts, evidence, creator,
            File.join(dir, "proof-inventory-#{name}")
          )
        end
      end
    end
  end

  def test_attestor_rejects_aggregate_retained_bundle_over_limit
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator = prepare_creator_evidence(dir, artifacts)
      %w[
        candidate-installed-manifest.json
        openclaw-installed-manifest.json
      ].each do |name|
        path = File.join(creator, name)
        installed = JSON.parse(File.read(path))
        installed["inventory"] = large_inventory
        HiveLiveAgentProof.write_json(path, installed)
        refresh_creator_bundle_record!(creator, name)
      end
      primary = File.join(creator, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(primary))
      receipt_path = File.join(creator, "execution-receipt.json")
      receipt = JSON.parse(File.read(receipt_path))
      receipt["installed_manifests"] = row.fetch("evidence_bundle").first(2)
      HiveLiveAgentProof.write_json(receipt_path, receipt)
      refresh_creator_bundle_record!(creator, "execution-receipt.json")
      sizes = HiveLiveAgentProof::WorkflowCreatorBundle::FILENAMES.map do |name|
        File.size(File.join(creator, name))
      end

      assert(
        sizes.all? do |size|
          size <= HiveLiveAgentProof::WorkflowCreatorBundle::MAX_FILE_BYTES
        end
      )
      assert_operator(
        sizes.sum,
        :>,
        HiveLiveAgentProof::WorkflowCreatorBundle::MAX_TOTAL_BYTES
      )
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(
          artifacts, evidence, creator,
          File.join(dir, "proof-aggregate-oversized")
        )
      end
      assert_includes error.message, "bundle is oversized"
    end
  end

  def test_attestor_normalizes_invalid_utf8_primary_and_sidecar
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator = prepare_creator_evidence(File.join(dir, "primary"), artifacts)
      File.binwrite(
        File.join(creator, "openclaw-workflow-creator.json"),
        invalid_utf8_json
      )
      primary_error = assert_raises(HiveLiveAgentProof::Error) do
        attest(
          artifacts, evidence, creator,
          File.join(dir, "proof-invalid-primary")
        )
      end

      creator = prepare_creator_evidence(File.join(dir, "sidecar"), artifacts)
      File.binwrite(
        File.join(creator, "candidate-installed-manifest.json"),
        invalid_utf8_json
      )
      refresh_creator_bundle_record!(
        creator,
        "candidate-installed-manifest.json"
      )
      sidecar_error = assert_raises(HiveLiveAgentProof::Error) do
        attest(
          artifacts, evidence, creator,
          File.join(dir, "proof-invalid-sidecar")
        )
      end

      assert_includes primary_error.message, "cannot be canonicalized"
      assert_includes sidecar_error.message, "cannot be canonicalized"
    end
  end

  def test_attestor_and_verifier_do_not_echo_malformed_json_bytes
    secret = "opaque-secret-ABCDEF"
    malformed = "{#{secret}}\n"

    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator = prepare_creator_evidence(File.join(dir, "primary"), artifacts)
      File.binwrite(
        File.join(creator, "openclaw-workflow-creator.json"),
        malformed
      )
      primary_error = assert_raises(HiveLiveAgentProof::Error) do
        attest(
          artifacts, evidence, creator,
          File.join(dir, "proof-malformed-primary")
        )
      end

      creator = prepare_creator_evidence(File.join(dir, "sidecar"), artifacts)
      File.binwrite(
        File.join(creator, "candidate-installed-manifest.json"),
        malformed
      )
      refresh_creator_bundle_record!(
        creator,
        "candidate-installed-manifest.json"
      )
      sidecar_error = assert_raises(HiveLiveAgentProof::Error) do
        attest(
          artifacts, evidence, creator,
          File.join(dir, "proof-malformed-sidecar")
        )
      end

      creator = prepare_creator_evidence(File.join(dir, "verifier"), artifacts)
      proof = File.join(dir, "proof")
      attest(artifacts, evidence, creator, proof)
      retained = File.join(proof, "evidence", "workflow-creator")
      File.binwrite(
        File.join(retained, "candidate-installed-manifest.json"),
        malformed
      )
      refresh_creator_bundle_record!(
        retained,
        "candidate-installed-manifest.json"
      )
      retained_primary =
        File.join(retained, "openclaw-workflow-creator.json")
      attestation_path = File.join(proof, "attestation.json")
      attestation = JSON.parse(File.read(attestation_path))
      attestation["workflow_creator"] =
        JSON.parse(File.read(retained_primary))
      HiveLiveAgentProof.write_json(attestation_path, attestation)
      verifier_error = assert_raises(HiveLiveAgentProof::Error) do
        verifier(
          proof,
          HiveLiveAgentProof.sha256(attestation_path)
        ).call
      end

      errors = {
        primary_error =>
          "workflow-creator evidence bundle entry is invalid JSON: " \
          "openclaw-workflow-creator.json",
        sidecar_error =>
          "workflow-creator evidence bundle entry is invalid JSON: " \
          "candidate-installed-manifest.json",
        verifier_error =>
          "workflow-creator evidence bundle entry is invalid JSON: " \
          "candidate-installed-manifest.json"
      }
      errors.each do |error, expected|
        assert_equal expected, error.message
        refute_includes error.message, secret
      end
    end
  end

  def test_verifier_normalizes_invalid_utf8_retained_sidecar
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator = prepare_creator_evidence(dir, artifacts)
      proof = File.join(dir, "proof")
      attest(artifacts, evidence, creator, proof)
      retained = File.join(proof, "evidence", "workflow-creator")
      File.binwrite(
        File.join(retained, "candidate-installed-manifest.json"),
        invalid_utf8_json
      )
      refresh_creator_bundle_record!(
        retained,
        "candidate-installed-manifest.json"
      )
      retained_primary =
        File.join(retained, "openclaw-workflow-creator.json")
      attestation_path = File.join(proof, "attestation.json")
      attestation = JSON.parse(File.read(attestation_path))
      attestation["workflow_creator"] =
        JSON.parse(File.read(retained_primary))
      HiveLiveAgentProof.write_json(attestation_path, attestation)

      error = assert_raises(HiveLiveAgentProof::Error) do
        verifier(
          proof,
          HiveLiveAgentProof.sha256(attestation_path)
        ).call
      end
      assert_includes error.message, "cannot be canonicalized"
    end
  end

  def test_attestor_normalizes_malformed_creator_values
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator = prepare_creator_evidence(dir, artifacts)
      primary = File.join(creator, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(primary))
      row["created_files"] = [
        row.fetch("created_files").first,
        "not-a-file-record"
      ]
      HiveLiveAgentProof.write_json(primary, row)

      assert_raises(HiveLiveAgentProof::Error) do
        attest(
          artifacts, evidence, creator,
          File.join(dir, "proof-malformed-creator")
        )
      end
    end
  end

  def test_attestor_rejects_missing_extra_or_wrong_type_creator_fields
    mutations = {
      "missing" => ->(row) { row.delete("task") },
      "extra" => ->(row) { row["unexpected"] = true },
      "wrong-type" => ->(row) { row["task_count"] = "1" }
    }

    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      mutations.each do |name, mutate|
        creator = prepare_creator_evidence(File.join(dir, name), artifacts)
        primary = File.join(creator, "openclaw-workflow-creator.json")
        row = JSON.parse(File.read(primary))
        mutate.call(row)
        HiveLiveAgentProof.write_json(primary, row)

        assert_raises(HiveLiveAgentProof::Error, name) do
          attest(
            artifacts, evidence, creator,
            File.join(dir, "proof-fields-#{name}")
          )
        end
      end
    end
  end

  def test_missing_failed_partial_or_unknown_execution_receipt_never_attests
    mutations = {
      "failed" => ->(receipt) { receipt["result"] = "failed" },
      "partial" => ->(receipt) { receipt.delete("teardown") },
      "unknown" => ->(receipt) { receipt["containment"]["status"] = "unknown" },
      "unbound" => ->(receipt) { receipt["installed_manifests"] = [] },
      "conflated" => lambda do |receipt|
        receipt["execution_kind"] = "authenticated_openclaw"
        receipt["model_loop"] = "executed"
      end
    }

    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      mutations.each do |name, mutate|
        creator = prepare_creator_evidence(File.join(dir, name), artifacts)
        receipt_path = File.join(creator, "execution-receipt.json")
        receipt = JSON.parse(File.read(receipt_path))
        mutate.call(receipt)
        HiveLiveAgentProof.write_json(receipt_path, receipt)
        refresh_creator_bundle_record!(creator, "execution-receipt.json")

        assert_raises(HiveLiveAgentProof::Error, name) do
          attest(
            artifacts, evidence, creator,
            File.join(dir, "proof-receipt-#{name}")
          )
        end
      end
    end
  end

  def test_nonpassing_temporary_receipt_is_uploadable_but_not_attestable
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator = File.join(dir, "creator-evidence")
      path = File.join(creator, "openclaw-workflow-creator.json")
      HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
                                                   .initialize!(candidate_sha: SHA)

      assert File.file?(path)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator, File.join(dir, "proof"))
      end
      assert_includes error.message, "bundle inventory is invalid"
    end
  end

  def test_atomic_store_replaces_nonpassing_receipt_with_validated_success
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      creator = prepare_creator_evidence(dir, artifacts)
      manifest = JSON.parse(
        File.read(File.join(artifacts, "artifact-manifest.json"))
      )
      path = File.join(creator, "openclaw-workflow-creator.json")
      success = JSON.parse(File.read(path))
      FileUtils.rm_f(path)
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
      store.initialize!(candidate_sha: SHA)

      stored = store.replace_success!(
        success,
        manifest: manifest,
        bundle_dir: creator,
        candidate_sha: SHA
      )

      assert_equal success, stored
      assert_equal success, JSON.parse(File.read(path))
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_atomic_store_rejects_a_mismatched_bundle_root_before_publication
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      creator = prepare_creator_evidence(dir, artifacts)
      manifest = JSON.parse(
        File.read(File.join(artifacts, "artifact-manifest.json"))
      )
      canonical_path =
        File.join(creator, "openclaw-workflow-creator.json")
      success = JSON.parse(File.read(canonical_path))
      other_path = File.join(dir, "other", "openclaw-workflow-creator.json")
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: other_path)
      store.initialize!(candidate_sha: SHA)
      previous = File.binread(other_path)

      assert_raises(HiveLiveAgentProof::Error) do
        store.replace_success!(
          success,
          manifest: manifest,
          bundle_dir: creator,
          candidate_sha: SHA
        )
      end

      assert_equal previous, File.binread(other_path)
    end
  end

  def test_validated_bundle_snapshot_copies_the_exact_bytes_it_checked
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      creator = prepare_creator_evidence(dir, artifacts)
      manifest = JSON.parse(
        File.read(File.join(artifacts, "artifact-manifest.json"))
      )
      primary = File.join(creator, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(primary))
      expected = HiveLiveAgentProof::WorkflowCreatorBundle::FILENAMES.to_h do |name|
        [ name, File.binread(File.join(creator, name)) ]
      end

      snapshot = HiveLiveAgentProof::WorkflowCreatorContract.validate_success!(
        row: row,
        manifest: manifest,
        candidate_sha: SHA,
        bundle_dir: creator
      )
      File.binwrite(
        File.join(creator, "execution-receipt.json"),
        "mutated after validation\n"
      )
      retained = File.join(dir, "retained")
      snapshot.copy_to!(retained)

      expected.each do |name, bytes|
        assert_equal bytes, File.binread(File.join(retained, name)), name
      end
    end
  end

  def test_atomic_store_rejects_an_exact_secret_in_supporting_evidence
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      creator = prepare_creator_evidence(dir, artifacts)
      manifest = JSON.parse(
        File.read(File.join(artifacts, "artifact-manifest.json"))
      )
      secret = "opaque-provider-credential"
      installed_path = File.join(creator, "openclaw-installed-manifest.json")
      installed = JSON.parse(File.read(installed_path))
      installed["identity"]["integrity"] = secret
      HiveLiveAgentProof.write_json(installed_path, installed)
      refresh_creator_bundle_record!(creator, "openclaw-installed-manifest.json")
      primary = File.join(creator, "openclaw-workflow-creator.json")
      row = JSON.parse(File.read(primary))
      receipt_path = File.join(creator, "execution-receipt.json")
      receipt = JSON.parse(File.read(receipt_path))
      receipt["installed_manifests"] = row.fetch("evidence_bundle").first(2)
      HiveLiveAgentProof.write_json(receipt_path, receipt)
      refresh_creator_bundle_record!(creator, "execution-receipt.json")
      path = File.join(creator, "openclaw-workflow-creator.json")
      success = JSON.parse(File.read(path))
      FileUtils.rm_f(path)
      store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: path)
      store.initialize!(candidate_sha: SHA)

      error = assert_raises(HiveLiveAgentProof::Error) do
        store.replace_success!(
          success,
          manifest: manifest,
          bundle_dir: creator,
          candidate_sha: SHA,
          exact_secrets: [ secret ]
        )
      end

      assert_includes error.message, "secret-shaped material"
      assert_equal "failed", JSON.parse(File.read(path)).fetch("result")
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
      expected = HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.map(&:dup)
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
    created_files = HiveLiveAgentProof::WORKFLOW_CREATOR_FILES.map do |path|
      { "path" => path, "sha256" => "c" * 64, "size" => 10 }
    end
    executed_instruction = created_files.find do |record|
      record["path"] == HiveLiveAgentProof::WORKFLOW_CREATOR_EXECUTED_INSTRUCTION
    end
    gem_name, gem_record = manifest.fetch("files").find do |name, _record|
      name.match?(/\Ahive-cli-[0-9].*\.gem\z/)
    end
    candidate_installation = {
      "schema" => HiveLiveAgentProof::WorkflowCreatorBundle::INSTALLED_MANIFEST_SCHEMA,
      "schema_version" => 1,
      "installation" => "candidate",
      "candidate_sha" => SHA,
      "identity" => {
        "kind" => "candidate_gem",
        "name" => "hive-cli",
        "version" => manifest.fetch("hive_version"),
        "artifact_sha256" => gem_record.fetch("sha256"),
        "artifact_size" => gem_record.fetch("size")
      },
      "inventory" => [
        { "path" => "bin/hive", "sha256" => "d" * 64, "size" => 100 }
      ]
    }
    openclaw_installation = {
      "schema" => HiveLiveAgentProof::WorkflowCreatorBundle::INSTALLED_MANIFEST_SCHEMA,
      "schema_version" => 1,
      "installation" => "openclaw",
      "candidate_sha" => SHA,
      "identity" => {
        "kind" => "openclaw_npm",
        "name" => "openclaw",
        "version" => "1.2.3",
        "integrity" => "sha512-fixture",
        "lock_sha256" => "e" * 64,
        "package_count" => 12
      },
      "inventory" => [
        { "path" => "bin/openclaw", "sha256" => "f" * 64, "size" => 200 }
      ]
    }
    HiveLiveAgentProof.write_json(
      File.join(evidence, "candidate-installed-manifest.json"),
      candidate_installation
    )
    HiveLiveAgentProof.write_json(
      File.join(evidence, "openclaw-installed-manifest.json"),
      openclaw_installation
    )
    bundle = [
      creator_bundle_record(
        evidence, "candidate_installation", "candidate-installed-manifest.json"
      ),
      creator_bundle_record(
        evidence, "openclaw_installation", "openclaw-installed-manifest.json"
      )
    ]
    execution_receipt = {
      "schema" => HiveLiveAgentProof::WorkflowCreatorBundle::EXECUTION_RECEIPT_SCHEMA,
      "schema_version" => 1,
      "candidate_sha" => SHA,
      "result" => "passed",
      "execution_kind" => "deterministic_fixture",
      "model_loop" => "not_exercised",
      "installed_manifests" => bundle,
      "hive_commands" => HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS,
      "executed_instruction" => executed_instruction,
      "external_actions" => [],
      "containment" => { "status" => "passed" },
      "teardown" => { "status" => "passed" },
      "cleanup" => { "status" => "passed" }
    }
    HiveLiveAgentProof.write_json(
      File.join(evidence, "execution-receipt.json"),
      execution_receipt
    )
    bundle << creator_bundle_record(
      evidence, "execution_receipt", "execution-receipt.json"
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
      "native_activation" => {
        "kind" => HiveLiveAgentProof::NATIVE_ACTIVATION_KINDS.fetch("openclaw"),
        "invocation" => HiveLiveAgentProof::INVOCATIONS.fetch("openclaw")
      },
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
        "status" => "passed",
        "scanner" => HiveLiveAgentProof::WorkflowCreatorContract::SCANNER
      },
      "cleanup" => { "status" => "passed" },
      "execution_kind" => "authenticated_openclaw",
      "model_loop" => "executed",
      "executed_instruction" => executed_instruction,
      "evidence_bundle" => bundle,
      "containment" => { "status" => "passed" },
      "teardown" => { "status" => "passed" }
    }
    HiveLiveAgentProof.write_json(File.join(evidence, "openclaw-workflow-creator.json"), row)
    evidence
  end

  def creator_bundle_record(root, kind, name)
    path = File.join(root, name)
    {
      "kind" => kind,
      "path" => name,
      "sha256" => Digest::SHA256.file(path).hexdigest,
      "size" => File.size(path)
    }
  end

  def inventory_record(path, size:)
    {
      "path" => path,
      "sha256" => "9" * 64,
      "size" => size
    }
  end

  def large_inventory
    padding = "x" * 1_905
    Array.new(
      HiveLiveAgentProof::WorkflowCreatorBundle::MAX_INVENTORY_ENTRIES
    ) do |index|
      inventory_record(
        format("files/%04d-%s", index, padding),
        size: 1
      )
    end
  end

  def invalid_utf8_json
    "{\"value\":\"\xFF\"}\n".b
  end

  def refresh_creator_bundle_record!(root, name)
    primary = File.join(root, "openclaw-workflow-creator.json")
    row = JSON.parse(File.read(primary))
    record = row.fetch("evidence_bundle").find do |candidate|
      candidate.fetch("path") == name
    end
    path = File.join(root, name)
    record["sha256"] = Digest::SHA256.file(path).hexdigest
    record["size"] = File.size(path)
    HiveLiveAgentProof.write_json(primary, row)
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
