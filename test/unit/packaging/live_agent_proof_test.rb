require "test_helper"
require "hive/agent_skills/canonical_skill"
require_relative "../../../packaging/live_agent_skills/proof"

class LiveAgentProofTest < Minitest::Test
  include HiveTestHelper

  SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  REPOSITORY = "ivankuznetsov/hive"
  Creator = HiveLiveAgentProof::WorkflowCreator

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

      assert_match(/hive-cli-#{Regexp.escape(Hive::VERSION)}\.gem\z/, verified.fetch("gem"))
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

  def test_attestor_rejects_workflow_creator_cross_binding_drift
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      path = File.join(creator_evidence, "candidate-installed-manifest.json")
      document = JSON.parse(File.read(path))
      document["candidate_sha"] = "c" * 40
      write_canonical_json(path, document)

      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-installation"))
      end
      assert_includes error.message, "workflow-creator"

      creator_evidence = prepare_creator_evidence(dir, artifacts)
      path = File.join(creator_evidence, "execution-receipt.json")
      receipt = JSON.parse(File.read(path))
      receipt["installed_manifests"].reverse!
      write_canonical_json(path, receipt)
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, File.join(dir, "proof-receipt"))
      end
      assert_includes error.message, "workflow-creator"
    end
  end

  def test_attestor_rejects_secrets_in_workflow_creator_support_members
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      creator_evidence = prepare_creator_evidence(dir, artifacts)
      row_path = File.join(creator_evidence, "openclaw-workflow-creator.json")
      receipt_path = File.join(creator_evidence, "execution-receipt.json")
      row = JSON.parse(File.read(row_path))
      receipt = JSON.parse(File.read(receipt_path))
      secret = "sk-ant-abcdefghijklmnop"
      receipt.fetch("run")["correlation_id"] = secret
      receipt.fetch("containment")["owner_correlation_id"] = secret
      bind_creator_receipt!(row, row.fetch("evidence_bundle"), receipt)
      write_canonical_json(receipt_path, receipt)
      write_canonical_json(row_path, row)

      proof = File.join(dir, "proof-secret")
      error = assert_raises(HiveLiveAgentProof::Error) do
        attest(artifacts, evidence, creator_evidence, proof)
      end
      assert_includes error.message, "secret scan failed"
      refute_path_exists proof
    end
  end

  def test_attestor_rejects_unsafe_workflow_creator_sources
    with_tmp_dir do |dir|
      artifacts = prepare_artifacts(dir)
      evidence = prepare_evidence(dir, artifacts)
      expected = {
        missing: "inventory", extra: "inventory", symlink: "regular file", hardlink: "regular file",
        public_root: "owner-private", public_member: "private regular file",
        oversize: "size limit", noncanonical: "canonical JSON"
      }
      expected.each do |kind, message|
        bundle = prepare_creator_evidence(File.join(dir, kind.to_s), artifacts)
        mutate_creator_bundle(bundle, kind, dir)
        error = assert_raises(HiveLiveAgentProof::Error, kind.to_s) do
          attest(artifacts, evidence, bundle, File.join(dir, "proof-#{kind}"))
        end
        assert_includes error.message, message, kind.to_s
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

      artifacts = prepare_artifacts(File.join(dir, "retained"))
      evidence = prepare_evidence(File.join(dir, "retained"), artifacts)
      creator_evidence = prepare_creator_evidence(File.join(dir, "retained"), artifacts)
      proof = File.join(dir, "proof-retained")
      result = attest(artifacts, evidence, creator_evidence, proof)
      numeric_substitution = deep_dup(result.dig("attestation", "workflow_creator"))
      numeric_substitution["task_count"] = 1.0
      assert_raises(HiveLiveAgentProof::Error) do
        HiveLiveAgentProof::WorkflowCreatorBundle.retained(
          directory: File.join(proof, "evidence"), expected_primary: numeric_substitution,
          manifest: result.dig("attestation", "artifacts"), candidate_sha: SHA
        )
      end
      retained = File.join(proof, "evidence", "openclaw-installed-manifest.json")
      File.open(retained, "ab") { |file| file.write(" ") }
      error = assert_raises(HiveLiveAgentProof::Error) { verifier(proof, result.fetch("sha256")).call }
      assert_includes error.message, "canonical JSON"
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
    FileUtils.mkdir_p(dir)
    artifacts = File.join(dir, "candidate")
    gem = write_file(File.join(dir, "hive-cli-#{Hive::VERSION}.gem"), "gem-bytes")
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
    FileUtils.mkdir_p(evidence, mode: 0o700)
    File.chmod(0o700, evidence)
    manifest = JSON.parse(File.read(File.join(artifacts, "artifact-manifest.json")))
    installations = %w[candidate openclaw].to_h do |kind|
      [ kind, creator_installation(kind, manifest) ]
    end
    records = creator_installation_records(installations)
    row = creator_primary_row(manifest, records)
    receipt = creator_execution_receipt(row, records, installations)
    bind_creator_receipt!(row, records, receipt)
    documents = {
      "openclaw-workflow-creator.json" => row,
      "candidate-installed-manifest.json" => installations.fetch("candidate"),
      "openclaw-installed-manifest.json" => installations.fetch("openclaw"),
      "execution-receipt.json" => receipt
    }
    documents.each { |name, document| write_canonical_json(File.join(evidence, name), document) }
    evidence
  end

  def mutate_creator_bundle(bundle, kind, root)
    receipt = File.join(bundle, "execution-receipt.json")
    case kind
    when :missing
      FileUtils.rm_f(receipt)
    when :extra
      File.write(File.join(bundle, "legacy.json"), "{}\n")
    when :symlink
      outside = File.join(root, "outside-receipt.json")
      FileUtils.mv(receipt, outside)
      File.symlink(outside, receipt)
    when :hardlink
      File.link(receipt, File.join(root, "receipt-hardlink.json"))
    when :public_root
      File.chmod(0o755, bundle)
    when :public_member
      File.chmod(0o644, receipt)
    when :oversize
      File.binwrite(receipt, " " * (1_048_576 + 1))
    when :noncanonical
      member = File.join(bundle, "candidate-installed-manifest.json")
      File.binwrite(member, JSON.pretty_generate(JSON.parse(File.read(member))) + "\n")
    end
  end

  def creator_installation(kind, manifest)
    roles = Creator::Vocabulary.fetch("member_roles").fetch(kind).to_h do |role|
      path = role == "package" ? "packages/#{kind}.pkg" : "#{role}/fixture"
      artifact = manifest.fetch("files").values_at("hive-cli-#{Hive::VERSION}.gem").first if
        kind == "candidate" && role == "package"
      [ role, { "path" => path, "sha256" => artifact&.fetch("sha256") || Digest::SHA256.hexdigest(path),
                "size" => artifact&.fetch("size") || path.bytesize } ]
    end
    dependency = {
      "path" => "runtime/dependency.rb", "sha256" => Digest::SHA256.hexdigest("dependency"), "size" => 21
    }
    inventory = [ *roles.values.map { |record| deep_dup(record) }, dependency ]
      .sort_by { |record| record.fetch("path") }
    closure = { "required_roles" => roles, "inventory" => inventory }
    {
      "schema" => Creator::Vocabulary.fetch("installed_schema"), "schema_version" => 1,
      "candidate_sha" => SHA, "kind" => kind,
      "version" => kind == "candidate" ? manifest.fetch("hive_version") : "fixture-openclaw",
      "closure_sha256" => Digest::SHA256.hexdigest(canonical(closure)), "required_roles" => roles,
      "inventory" => inventory, "total_size" => inventory.sum { |record| record.fetch("size") },
      "secret_scan" => creator_passing_scan
    }
  end

  def creator_installation_records(installations)
    records = %w[candidate openclaw].each_with_index.map do |kind, index|
      bytes = canonical(installations.fetch(kind))
      {
        "kind" => "#{kind}_installation",
        "path" => Creator::Vocabulary.fetch("bundle_files").fetch(index + 1),
        "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize
      }
    end
    records << {
      "kind" => "execution_receipt", "path" => "execution-receipt.json",
      "sha256" => Digest::SHA256.hexdigest("pending"), "size" => 1
    }
  end

  def creator_primary_row(manifest, records)
    created = Creator::Vocabulary.fetch("files").map do |path|
      { "path" => path, "sha256" => Digest::SHA256.hexdigest(path), "size" => path.bytesize }
    end
    summary = { "status" => "passed", "receipt_sha256" => records.fetch(2).fetch("sha256") }
    {
      "schema" => Creator::Vocabulary.fetch("evidence_schema"), "schema_version" => 1,
      "platform" => "openclaw", "candidate_sha" => SHA, "result" => "passed",
      "prompt_sha256" => Digest::SHA256.hexdigest(Creator::Vocabulary.fetch("prompt")),
      "task_prompt_sha256" => Digest::SHA256.hexdigest(Creator::Vocabulary.fetch("task_prompt")),
      "skill" => manifest.slice("skill_version", "canonical_digest"),
      "native_activation" => deep_dup(Creator::Vocabulary.fetch("native_activation")),
      "hive_commands" => deep_dup(Creator::Vocabulary.fetch("commands")), "created_files" => created,
      "validation" => deep_dup(Creator::Vocabulary.fetch("graph")), "creation_only_task_count" => 0,
      "task_count" => 1, "task" => deep_dup(Creator::Vocabulary.fetch("task")), "external_actions" => [],
      "secret_scan" => creator_passing_scan, "execution_kind" => "authenticated_openclaw",
      "model_loop" => "executed", "executed_instruction" => deep_dup(created.fetch(2)),
      "evidence_bundle" => deep_dup(records), "containment" => deep_dup(summary),
      "teardown" => deep_dup(summary), "cleanup" => deep_dup(summary)
    }
  end

  def creator_execution_receipt(row, records, installations)
    command_labels = Creator::Vocabulary.fetch("commands").each_index.map do |index|
      format("command-%02d", index + 1)
    end
    commands = Creator::Vocabulary.fetch("commands").each_with_index.map do |argv, index|
      creator_process_receipt("attempt_label" => command_labels.fetch(index)).merge(
        "position" => index + 1, "argv" => deep_dup(argv)
      )
    end
    outer = Creator::Vocabulary.fetch("outer_roles").each_with_index.map do |identity, index|
      creator_process_receipt("label" => %w[outer-workflow-creator outer-authorized-work].fetch(index)).merge(
        deep_dup(identity), "argv_sha256" => Digest::SHA256.hexdigest("outer-#{index}")
      )
    end
    labels = command_labels + outer.map { |process| process.fetch("label") }
    correlation = "workflow-creator-proof-run"
    archives = installations.values.map { |document| document.dig("required_roles", "package") }
      .each_with_index.map do |package, index|
      {
        "label" => Creator::Vocabulary.fetch("archive_labels").fetch(index),
        "artifact_sha256" => package.fetch("sha256"), "artifact_size" => package.fetch("size"),
        "policy_sha256" => Creator::Vocabulary.fetch("archive_policy_sha256"),
        "entry_count" => 5, "uncompressed_bytes" => 1_024, "status" => "passed"
      }
    end
    instruction = deep_dup(row.fetch("executed_instruction"))
    {
      "schema" => Creator::Vocabulary.fetch("execution_schema"), "schema_version" => 1,
      "candidate_sha" => SHA, "result" => "passed",
      "execution_plan" => Creator::Vocabulary.fetch("execution_plan"),
      "classification" => {
        "outer" => deep_dup(Creator::Vocabulary.fetch("classification")),
        "nested_stage" => { "execution_kind" => "deterministic_fixture", "model_loop" => "not_exercised" }
      },
      "installed_manifests" => deep_dup(records.first(2)),
      "run" => { "correlation_id" => correlation, "expected_labels" => labels },
      "gateway" => {
        "identity" => deep_dup(installations.fetch("candidate").dig("required_roles", "audit_gateway")),
        "command_labels" => command_labels, "status" => "passed"
      },
      "archive_admissions" => archives, "commands" => commands, "outer_processes" => outer,
      "authored_instruction" => deep_dup(instruction), "executed_instruction" => instruction,
      "external_actions" => [],
      "containment" => {
        "status" => "passed", "mechanism" => "supervised-process-tree", "established_before_launch" => true,
        "owner_correlation_id" => correlation, "root_loss_behavior" => "fail-closed"
      },
      "teardown" => {
        "status" => "passed", "expected_labels" => labels, "receipt_labels" => deep_dup(labels),
        "outer_root_reaped" => true, "remaining_descendants" => 0
      },
      "cleanup" => { "status" => "passed", "targets" => [
        { "label" => "proof-workspace", "path_sha256" => Digest::SHA256.hexdigest("workspace"),
          "device" => 1, "inode" => 2, "created_by_run" => true,
          "identity_matched" => true, "removed" => true }
      ] },
      "secret_scan" => creator_passing_scan
    }
  end

  def creator_process_receipt(label)
    label.merge(
      "exit_code" => 0, "signal" => nil, "completed" => true,
      "capture" => {
        "limit_bytes" => 4_096, "stdout_bytes" => 0, "stderr_bytes" => 0,
        "stdout_sha256" => Digest::SHA256.hexdigest(""), "stderr_sha256" => Digest::SHA256.hexdigest(""),
        "stdout_truncated" => false, "stderr_truncated" => false, "secret_scan" => creator_passing_scan
      },
      "teardown" => {
        "status" => "passed", "term_sent" => false, "kill_sent" => false,
        "reaped" => true, "descendants" => "none", "owner_complete" => true
      }
    )
  end

  def bind_creator_receipt!(row, records, receipt)
    bytes = canonical(receipt)
    record = records.fetch(2)
    record["sha256"], record["size"] = Digest::SHA256.hexdigest(bytes), bytes.bytesize
    row.fetch("evidence_bundle")[2] = deep_dup(record)
    summary = { "status" => "passed", "receipt_sha256" => record.fetch("sha256") }
    %w[containment teardown cleanup].each { |field| row[field] = deep_dup(summary) }
  end

  def write_canonical_json(path, value)
    File.binwrite(path, canonical(value))
    File.chmod(0o600, path)
  end

  def canonical(value) = Creator::Values.capture(value).canonical_bytes
  def creator_passing_scan = { "status" => "passed", "scanner" => Creator::Vocabulary.fetch("scanner") }
  def deep_dup(value) = Marshal.load(Marshal.dump(value))

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
