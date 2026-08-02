require "test_helper"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "ripper"
require_relative "../../../packaging/live_agent_skills/workflow_creator"

class WorkflowCreatorCoreTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SHA = "a" * 40
  DIGEST = "b" * 64
  CREATOR = HiveLiveAgentProof::WorkflowCreator

  def test_public_api_and_schema_v1_vocabulary_are_exact
    assert_equal(
      %i[
        canonical_json failure validate_execution! validate_installation!
        validate_nonpassing! validate_primary!
      ],
      CREATOR.singleton_methods(false).sort
    )
    assert CREATOR::Error < StandardError
    assert_includes CREATOR.method(:validate_execution!).parameters, [ :keyreq, :manifest ]
    execution_contract = CREATOR.const_get(:ExecutionContract, false)
    assert_includes execution_contract.method(:validate!).parameters, [ :keyreq, :manifest ]
    assert_equal %w[
      schema_version evidence_schema installed_schema execution_schema
      execution_plan scanner request prompt task_request task_key task_slug
      task_prompt task_new_argv commands files executed_instruction
      native_activation graph task classification bundle_files member_roles
      outer_roles archive_labels archive_policy_sha256 cleanup_labels
    ], vocabulary.keys
    assert_equal 1, vocabulary.fetch("schema_version")
    assert_equal "hive-live-workflow-creator-evidence",
                 vocabulary.fetch("evidence_schema")
    assert_equal "hive-live-workflow-creator-installed-manifest",
                 vocabulary.fetch("installed_schema")
    assert_equal "hive-live-workflow-creator-execution-receipt",
                 vocabulary.fetch("execution_schema")
    assert_equal "hive-live-workflow-creator-execution-plan/v1",
                 vocabulary.fetch("execution_plan")
    assert_equal expected_prompt, vocabulary.fetch("prompt")
    assert_equal expected_task_prompt, vocabulary.fetch("task_prompt")
    assert_equal expected_commands, vocabulary.fetch("commands")
    assert_equal expected_commands.fetch(5), vocabulary.fetch("task_new_argv")
    assert_equal expected_files, vocabulary.fetch("files")
    assert_equal expected_files.fetch(2), vocabulary.fetch("executed_instruction")
    assert_equal({ "kind" => "openclaw-skills-info", "invocation" => "/hive" },
                 vocabulary.fetch("native_activation"))
    assert_equal expected_graph, vocabulary.fetch("graph")
    assert_equal expected_task, vocabulary.fetch("task")
    assert_equal(
      { "execution_kind" => "authenticated_openclaw", "model_loop" => "executed" },
      vocabulary.fetch("classification")
    )
    assert_equal %w[
      openclaw-workflow-creator.json candidate-installed-manifest.json
      openclaw-installed-manifest.json execution-receipt.json
    ], vocabulary.fetch("bundle_files")
    assert_equal(
      {
        "candidate" => %w[audit_gateway executable interpreter_or_launcher lock package],
        "openclaw" => %w[executable interpreter_or_launcher lock package]
      },
      vocabulary.fetch("member_roles")
    )
    assert_equal(
      [
        { "role" => "workflow-creation-model-loop", "prompt_sha256" => Digest::SHA256.hexdigest(expected_prompt) },
        { "role" => "authorized-work-model-loop", "prompt_sha256" => Digest::SHA256.hexdigest(expected_task_prompt) }
      ],
      vocabulary.fetch("outer_roles")
    )
    assert_equal %w[candidate-package openclaw-package], vocabulary.fetch("archive_labels")
    assert_equal Digest::SHA256.hexdigest("hive-live-workflow-creator-archive-policy/v1"),
                 vocabulary.fetch("archive_policy_sha256")
    assert_equal %w[proof-workspace], vocabulary.fetch("cleanup_labels")
  end

  def test_vocabulary_is_recursively_immutable_including_computed_digests
    leaves = []
    walk = lambda do |value, path|
      assert_predicate value, :frozen?, path
      case value
      when Hash
        assert_raises(FrozenError, path) { value["mutation"] = true }
        value.each do |key, nested|
          walk.call(key, "#{path}{key:#{key}}")
          walk.call(nested, "#{path}.#{key}")
        end
      when Array
        assert_raises(FrozenError, path) { value << "mutation" }
        value.each_with_index { |nested, index| walk.call(nested, "#{path}[#{index}]") }
      when String
        leaves << [ path, value ]
        assert_raises(FrozenError, path) { value.replace("mutation") }
      end
    end

    walk.call(vocabulary, "Vocabulary")
    digest_paths = leaves.filter_map { |path, value| path if value.match?(/\A[0-9a-f]{64}\z/) }
    assert_includes digest_paths, "Vocabulary.outer_roles[0].prompt_sha256"
    assert_includes digest_paths, "Vocabulary.outer_roles[1].prompt_sha256"
    assert_includes digest_paths, "Vocabulary.archive_policy_sha256"
    assert_equal expected_commands, vocabulary.fetch("commands")
    classifications = CREATOR.const_get(:Contract, false).const_get(:CLASSIFICATIONS, false)
    walk.call(classifications, "Contract.CLASSIFICATIONS")
  end

  def test_canonical_json_and_nonpassing_documents_are_bounded_and_secret_safe
    left = { "z" => { "b" => 2, "a" => 1 }, "a" => [ { "d" => 4, "c" => 3 } ] }
    right = { "a" => [ { "c" => 3, "d" => 4 } ], "z" => { "a" => 1, "b" => 2 } }
    assert_equal CREATOR.canonical_json(left), CREATOR.canonical_json(right)
    assert_equal <<~JSON, CREATOR.canonical_json({ "b" => 2, "a" => 1 })
      {
        "a": 1,
        "b": 2
      }
    JSON
    [ { invalid: true }, "\xFF".b, Object.new, Float::NAN ].each do |value|
      error = assert_raises(CREATOR::Error) { CREATOR.canonical_json(value) }
      assert_equal "cannot canonicalize JSON", error.message
    end
    deeply_nested = []
    128.times { deeply_nested = [ deeply_nested ] }
    assert_raises(CREATOR::Error) { CREATOR.canonical_json(deeply_nested) }
    assert_raises(CREATOR::Error) { CREATOR.canonical_json(Array.new(16_385, 0)) }
    json_limit = CREATOR.const_get(:Primitives, false).const_get(:MAX_JSON_BYTES, false)
    assert_raises(CREATOR::Error) { CREATOR.canonical_json("x" * (json_limit + 1)) }
    assert_raises(CREATOR::Error) { CREATOR.canonical_json({ "x" * (json_limit + 1) => 0 }) }
    assert_raises(CREATOR::Error) do
      CREATOR.canonical_json([ "x" * (json_limit / 2), "y" * (json_limit / 2) ])
    end

    row = CREATOR.failure(
      candidate_sha: SHA, phase: "preflight", reason: "provider_unavailable",
      detail: "exact-fixture-secret #{secret_shape}#{'x' * 1_100}",
      exact_secrets: [ "exact-fixture-secret" ]
    )
    assert_equal %w[
      candidate_sha detail execution_kind model_loop phase platform reason
      result schema schema_version secret_scan
    ], row.keys.sort
    assert_equal "failed", row.fetch("result")
    assert_equal 2, row.fetch("detail").scan("[REDACTED]").length
    assert_operator row.fetch("detail").bytesize, :<=, 1_000
    assert_same row, CREATOR.validate_nonpassing!(row)
    unresolved = CREATOR.failure(candidate_sha: "unknown", phase: "preflight", reason: "not_started")
    assert_equal "unresolved", unresolved.fetch("candidate_sha")
    assert_nil unresolved.fetch("detail")

    [
      ->(value) { value["unexpected"] = true },
      ->(value) { value["schema_version"] = 1.0 },
      ->(value) { value["result"] = "passed" },
      ->(value) { value["candidate_sha"] = ("1" * 40).to_i },
      ->(value) { value["phase"] = :preflight },
      ->(value) { value["phase"] = "not-valid!" },
      ->(value) { value["model_loop"] = "executed" },
      ->(value) { value["detail"] = secret_shape },
      ->(value) { value["detail"] = "\xFF".b }
    ].each do |mutation|
      invalid = deep_dup(row)
      mutation.call(invalid)
      assert_raises(CREATOR::Error) { CREATOR.validate_nonpassing!(invalid) }
    end
    assert_raises(CREATOR::Error) { CREATOR.validate_nonpassing!(nil) }

    %i[phase reason].each do |field|
      secret = "databasepassword0123456789"
      arguments = { candidate_sha: SHA, phase: "preflight", reason: "provider_unavailable",
                    exact_secrets: [ secret ] }
      arguments[field] = secret
      assert_raises(CREATOR::Error, field.to_s) { CREATOR.failure(**arguments) }
    end
    [ "databasepassword0123456789", { "api_key" => "databasepassword0123456789" } ].each do |secrets|
      assert_raises(CREATOR::Error) do
        CREATOR.failure(candidate_sha: SHA, phase: "preflight", reason: "provider_unavailable",
                        detail: "databasepassword0123456789", exact_secrets: secrets)
      end
    end
    [ Array.new(65) { |index| "absent-secret-#{index}" }, [ "x" * 4_097 ], [ "" ], [ "\xFF".b ] ].each do |secrets|
      assert_raises(CREATOR::Error) do
        CREATOR.failure(candidate_sha: SHA, phase: "preflight", reason: "provider_unavailable",
                        exact_secrets: secrets)
      end
    end
  end

  def test_canonical_json_rejects_projected_expansion_before_pretty_serialization
    json_limit = CREATOR.const_get(:Primitives, false).const_get(:MAX_JSON_BYTES, false)
    adversarial = {
      "nul-expansion" => "\0" * json_limit,
      "oversized-integer" => 1 << (json_limit * 4)
    }

    adversarial.each do |label, value|
      serializer = ->(*) { raise Minitest::Assertion, "pretty serializer reached for #{label}" }
      original = JSON.method(:pretty_generate)
      JSON.define_singleton_method(:pretty_generate, serializer)
      begin
        error = assert_raises(CREATOR::Error, label) { CREATOR.canonical_json(value) }
        assert_equal "cannot canonicalize JSON", error.message
      ensure
        JSON.define_singleton_method(:pretty_generate, original)
      end
    end
  end

  def test_public_validation_boundaries_reject_json_subclasses
    hostile_hash = Class.new(Hash) { def keys = [] }
    hostile_array = Class.new(Array) { def map = [] }
    hostile_string = Class.new(String) do
      def ==(_other) = true
      def bytesize = 0
      def valid_encoding? = true
    end
    plain_hash = Class.new(Hash)
    plain_array = Class.new(Array)
    plain_string = Class.new(String)

    cases = {
      "canonical-hash-enumeration" => -> { CREATOR.canonical_json(hostile_hash["hidden" => true]) },
      "canonical-array-enumeration" => -> { CREATOR.canonical_json(hostile_array["hidden"]) },
      "canonical-string-accounting" => -> { CREATOR.canonical_json(hostile_string.new("passed")) },
      "failure-candidate-string" => lambda do
        CREATOR.failure(candidate_sha: plain_string.new(SHA), phase: "preflight", reason: "not_started")
      end,
      "nonpassing-equality" => lambda do
        row = CREATOR.failure(candidate_sha: SHA, phase: "preflight", reason: "not_started")
        row["result"] = hostile_string.new("passed")
        CREATOR.validate_nonpassing!(row)
      end,
      "primary-hash" => lambda do
        fixture = valid_fixture
        fixture[:row] = plain_hash.new.merge!(fixture.fetch(:row))
        validate_primary(fixture)
      end,
      "installation-array" => lambda do
        fixture = valid_fixture
        document = fixture.fetch(:installations).fetch("openclaw")
        document["inventory"] = plain_array.new.concat(document.fetch("inventory"))
        CREATOR.validate_installation!(document:, kind: "openclaw",
                                       manifest: fixture.fetch(:manifest), candidate_sha: SHA)
      end,
      "execution-label-string" => lambda do
        fixture = valid_fixture
        label = fixture.fetch(:receipt).fetch("commands").first.fetch("attempt_label")
        fixture.fetch(:receipt).fetch("commands").first["attempt_label"] = plain_string.new(label)
        validate_execution(fixture)
      end
    }
    accepted = cases.filter_map do |label, action|
      action.call
      label
    rescue CREATOR::Error
      nil
    end
    assert_empty accepted, "subclass-backed evidence admitted: #{accepted.join(', ')}"
  end

  def test_failure_redaction_merges_overlapping_original_ranges
    cases = {
      "exact-exact" => [ "token=abcdefghij", %w[abc abcdefghij] ],
      "exact-pattern" => [ "token=#{secret_shape}", [ "sk-ant-abc" ] ]
    }
    cases.each do |label, (detail, exact_secrets)|
      row = CREATOR.failure(candidate_sha: SHA, phase: "preflight", reason: "provider_unavailable",
                            detail:, exact_secrets:)
      assert_equal "token=[REDACTED]", row.fetch("detail"), label
      refute_match(/defghij/, row.fetch("detail"), label)
    end
  end

  def test_failure_rejects_raw_detail_above_the_documented_work_ceiling
    contract = CREATOR.const_get(:Contract, false)
    assert_equal 4_096, contract.const_get(:MAX_DETAIL_INPUT_BYTES, false)
    exact_secrets = 64.times.map { |index| format("absent-secret-%02d", index) }
    assert_raises(CREATOR::Error) do
      CREATOR.failure(candidate_sha: SHA, phase: "preflight", reason: "provider_unavailable",
                      detail: "x" * 4_097, exact_secrets:)
    end
  end

  def test_public_strings_reject_non_utf8_with_domain_errors
    utf16_sha = SHA.encode(Encoding::UTF_16LE)
    cases = {
      "canonical-key" => -> { CREATOR.canonical_json({ "key".encode(Encoding::UTF_16LE) => true }) },
      "failure-candidate-sha" => lambda do
        CREATOR.failure(candidate_sha: utf16_sha, phase: "preflight", reason: "not_started")
      end,
      "failure-phase" => lambda do
        CREATOR.failure(candidate_sha: SHA, phase: "preflight".encode(Encoding::UTF_16LE), reason: "not_started")
      end,
      "primary-candidate-sha" => lambda do
        fixture = valid_fixture
        CREATOR.validate_primary!(row: fixture.fetch(:row), manifest: fixture.fetch(:manifest),
                                  candidate_sha: utf16_sha, bundle_records: fixture.fetch(:bundle_records))
      end,
      "installation-path" => lambda do
        fixture = valid_fixture
        document = fixture.fetch(:installations).fetch("openclaw")
        document.fetch("inventory").last["path"] = "runtime/dependency.rb".encode(Encoding::UTF_16LE)
        CREATOR.validate_installation!(document:, kind: "openclaw",
                                       manifest: fixture.fetch(:manifest), candidate_sha: SHA)
      end,
      "execution-label" => lambda do
        fixture = valid_fixture
        fixture.fetch(:receipt).fetch("commands").first["attempt_label"] =
          "command-01".encode(Encoding::UTF_16LE)
        validate_execution(fixture)
      end
    }
    boundary_leaks = cases.filter_map do |label, action|
      action.call
      "#{label}:accepted"
    rescue CREATOR::Error
      nil
    rescue EncodingError => error
      "#{label}:#{error.class}"
    end
    assert_empty boundary_leaks, "non-UTF-8 boundary leaks: #{boundary_leaks.join(', ')}"
  end

  def test_primary_contract_accepts_exact_claims_and_rejects_key_type_order_and_binding_drift
    fixture = valid_fixture
    assert_same fixture.fetch(:row), validate_primary(fixture)
    cases = {
      "extra-key" => ->(item) { item[:row]["unexpected"] = true },
      "schema-float" => ->(item) { item[:row]["schema_version"] = 1.0 },
      "manifest-schema-float" => ->(item) { item[:manifest]["schema_version"] = 1.0 },
      "manifest-record-float" => ->(item) { item[:manifest]["files"].values.first["size"] = 10.0 },
      "manifest-record-extra" => ->(item) { item[:manifest]["files"].values.first["path"] = "x" },
      "prompt" => ->(item) { item[:row]["prompt_sha256"] = DIGEST },
      "command-order" => ->(item) { item[:row]["hive_commands"].reverse! },
      "created-order" => ->(item) { item[:row]["created_files"].reverse! },
      "created-size-float" => ->(item) { item[:row]["created_files"][0]["size"] = 10.0 },
      "graph" => ->(item) { item[:row]["validation"]["stages"] << "publish" },
      "task-count-float" => ->(item) { item[:row]["task_count"] = 1.0 },
      "run-count-float" => ->(item) { item[:row]["task"]["run_count"] = 1.0 },
      "authored" => ->(item) { item[:row]["executed_instruction"]["sha256"] = DIGEST },
      "bundle-order" => ->(item) { item[:row]["evidence_bundle"].reverse! },
      "bundle-size-float" => ->(item) { item[:row]["evidence_bundle"][0]["size"] = 12.0 },
      "argument-bundle-float" => ->(item) { item[:bundle_records][0]["size"] = 12.0 },
      "summary" => ->(item) { item[:row]["cleanup"]["receipt_sha256"] = DIGEST },
      "classification" => ->(item) { item[:row]["model_loop"] = "not_exercised" },
      "external-effect" => ->(item) { item[:row]["external_actions"] << "publish" }
    }
    cases.each do |label, mutation|
      invalid = valid_fixture
      mutation.call(invalid)
      assert_raises(CREATOR::Error, label) { validate_primary(invalid) }
    end
    %i[row manifest bundle_records].each do |field|
      invalid = valid_fixture.merge(field => nil)
      assert_raises(CREATOR::Error, field.to_s) { validate_primary(invalid) }
    end
  end

  def test_installed_closure_contract_is_exact_typed_ordered_and_manifest_bound
    fixture = valid_fixture
    %w[candidate openclaw].each do |kind|
      document = fixture.fetch(:installations).fetch(kind)
      assert_same document, CREATOR.validate_installation!(
        document:, kind:, manifest: fixture.fetch(:manifest), candidate_sha: SHA
      )
    end
    cases = {
      "extra-key" => ->(item) { item[:document]["unexpected"] = true },
      "schema-float" => ->(item) { item[:document]["schema_version"] = 1.0 },
      "inventory-order" => ->(item) { item[:document]["inventory"].reverse! },
      "inventory-duplicate" => ->(item) { item[:document]["inventory"] << deep_dup(item[:document]["inventory"].last) },
      "inventory-size-float" => ->(item) { item[:document]["inventory"][0]["size"] = 1.0 },
      "missing-role" => ->(item) { item[:document]["required_roles"].delete("executable") },
      "role-not-inventory" => ->(item) { item[:document]["required_roles"]["executable"]["sha256"] = DIGEST },
      "duplicate-role-path" => lambda do |item|
        item[:document]["required_roles"]["executable"] = deep_dup(item[:document]["required_roles"]["lock"])
      end,
      "closure" => ->(item) { item[:document]["closure_sha256"] = DIGEST },
      "total-float" => ->(item) { item[:document]["total_size"] = item[:document]["total_size"].to_f },
      "secret" => ->(item) { item[:document]["version"] = secret_shape },
      "package" => ->(item) { item[:document]["required_roles"]["package"]["sha256"] = DIGEST },
      "manifest-nil" => ->(item) { item[:manifest] = nil },
      "manifest-files" => ->(item) { item[:manifest]["files"] = nil },
      "manifest-candidate" => ->(item) { item[:manifest]["candidate_sha"] = "c" * 40 }
    }
    cases.each do |label, mutation|
      item = {
        document: deep_dup(fixture.fetch(:installations).fetch("candidate")),
        manifest: deep_dup(fixture.fetch(:manifest))
      }
      mutation.call(item)
      assert_raises(CREATOR::Error, label) do
        CREATOR.validate_installation!(document: item[:document], kind: "candidate",
                                       manifest: item[:manifest], candidate_sha: SHA)
      end
    end
    openclaw = deep_dup(fixture.fetch(:installations).fetch("openclaw"))
    openclaw["version"] = ""
    assert_raises(CREATOR::Error) do
      CREATOR.validate_installation!(document: openclaw, kind: "openclaw",
                                     manifest: fixture.fetch(:manifest), candidate_sha: SHA)
    end

    zero_package = deep_dup(fixture.fetch(:installations).fetch("openclaw"))
    package = zero_package.fetch("required_roles").fetch("package")
    package["size"] = 0
    zero_package.fetch("inventory").find { |item| item["path"] == package["path"] }["size"] = 0
    refresh_installation!(zero_package)
    assert_raises(CREATOR::Error) do
      CREATOR.validate_installation!(document: zero_package, kind: "openclaw",
                                     manifest: fixture.fetch(:manifest), candidate_sha: SHA)
    end
  end

  def test_artifact_manifests_reject_invalid_utf8_before_identity_use
    fixture = valid_fixture
    fixture.fetch(:manifest)["skill_version"] = "\xFF".b
    fixture.fetch(:row).fetch("skill")["skill_version"] = "\xFF".b

    assert_raises(CREATOR::Error) { validate_primary(fixture) }
    assert_raises(CREATOR::Error) do
      CREATOR.validate_installation!(
        document: fixture.fetch(:installations).fetch("openclaw"), kind: "openclaw",
        manifest: fixture.fetch(:manifest), candidate_sha: SHA
      )
    end
  end

  def test_execution_contract_is_a_closed_declarative_transaction
    fixture = valid_fixture
    assert_same fixture.fetch(:receipt), validate_execution(fixture)
    cases = {
      "extra-key" => ->(item) { item[:receipt]["unexpected"] = true },
      "schema-float" => ->(item) { item[:receipt]["schema_version"] = 1.0 },
      "classification" => ->(item) { item[:receipt]["classification"]["outer"]["model_loop"] = "not_exercised" },
      "installed-size-float" => ->(item) { item[:receipt]["installed_manifests"][0]["size"] = 10.0 },
      "gateway-size-float" => ->(item) { item[:receipt]["gateway"]["identity"]["size"] = 10.0 },
      "archive-order" => ->(item) { item[:receipt]["archive_admissions"].reverse! },
      "archive-size-float" => ->(item) { item[:receipt]["archive_admissions"][0]["artifact_size"] = 10.0 },
      "archive-policy" => ->(item) { item[:receipt]["archive_admissions"][0]["policy_sha256"] = DIGEST },
      "command-order" => ->(item) { item[:receipt]["commands"].reverse! },
      "command-position-float" => ->(item) { item[:receipt]["commands"][0]["position"] = 1.0 },
      "command-argv" => ->(item) { item[:receipt]["commands"][0]["argv"] = [ "doctor" ] },
      "capture-limit-float" => ->(item) { item[:receipt]["commands"][0]["capture"]["limit_bytes"] = 4_096.0 },
      "capture-bound" => ->(item) { item[:receipt]["commands"][0]["capture"]["stdout_bytes"] = 4_097 },
      "kill-before-term" => lambda do |item|
        item[:receipt]["commands"][0]["teardown"]["kill_sent"] = true
        item[:receipt]["commands"][0]["teardown"]["term_sent"] = false
      end,
      "outer-order" => ->(item) { item[:receipt]["outer_processes"].reverse! },
      "outer-alias" => lambda do |item|
        item[:receipt]["outer_processes"][1]["argv_sha256"] = item[:receipt]["outer_processes"][0]["argv_sha256"]
      end,
      "duplicate-label" => lambda do |item|
        item[:receipt]["outer_processes"][0]["label"] = item[:receipt]["commands"][0]["attempt_label"]
      end,
      "run-order" => ->(item) { item[:receipt]["run"]["expected_labels"].reverse! },
      "containment" => ->(item) { item[:receipt]["containment"]["established_before_launch"] = false },
      "teardown-float" => ->(item) { item[:receipt]["teardown"]["remaining_descendants"] = 0.0 },
      "cleanup-inode-float" => ->(item) { item[:receipt]["cleanup"]["targets"][0]["inode"] = 2.0 },
      "cleanup-custody" => ->(item) { item[:receipt]["cleanup"]["targets"][0]["identity_matched"] = false },
      "authored-size-float" => ->(item) { item[:receipt]["authored_instruction"]["size"] = 10.0 },
      "row-instruction-float" => ->(item) { item[:row]["executed_instruction"]["size"] = 10.0 },
      "executed-binding" => ->(item) { item[:receipt]["executed_instruction"]["sha256"] = DIGEST },
      "external-effect" => ->(item) { item[:receipt]["external_actions"] << "publish" },
      "summary" => ->(item) { item[:row]["cleanup"]["receipt_sha256"] = DIGEST },
      "secret" => lambda do |item|
        item[:receipt]["run"]["correlation_id"] = secret_shape
        item[:receipt]["containment"]["owner_correlation_id"] = secret_shape
      end
    }
    cases.each do |label, mutation|
      invalid = valid_fixture
      mutation.call(invalid)
      assert_raises(CREATOR::Error, label) { validate_execution(invalid) }
    end
    invalid = valid_fixture.merge(receipt: nil)
    assert_raises(CREATOR::Error) { validate_execution(invalid) }
  end

  def test_execution_capture_tuples_bind_counts_digests_and_truncation
    cases = {
      "zero-byte-stdout-digest" => lambda do |capture|
        capture["stdout_sha256"] = DIGEST
      end,
      "short-truncated-stderr" => lambda do |capture|
        capture["stderr_bytes"] = capture.fetch("limit_bytes") - 1
        capture["stderr_sha256"] = DIGEST
        capture["stderr_truncated"] = true
      end
    }
    accepted = cases.filter_map do |label, mutation|
      fixture = valid_fixture
      mutation.call(fixture.fetch(:receipt).fetch("commands").first.fetch("capture"))
      rebind_execution_receipt!(fixture)
      validate_execution(fixture)
      label
    rescue CREATOR::Error => error
      assert_equal "workflow-creator execution process receipt is invalid", error.message, label
      nil
    end
    assert_empty accepted, "incoherent capture tuples admitted: #{accepted.join(', ')}"
  end

  def test_execution_contract_binds_all_canonical_document_bytes_and_kinds
    cases = {
      "swapped-documents" => lambda do |item|
        candidate = item[:installations].fetch("candidate")
        item[:installations]["candidate"] = item[:installations].fetch("openclaw")
        item[:installations]["openclaw"] = candidate
      end,
      "duplicated-candidate-document" => lambda do |item|
        item[:installations]["openclaw"] = deep_dup(item[:installations].fetch("candidate"))
        rebind_installation_record!(item, 1, "openclaw")
        package = item[:installations].fetch("candidate").dig("required_roles", "package")
        item[:receipt].fetch("archive_admissions")[1]["artifact_sha256"] = package.fetch("sha256")
        item[:receipt].fetch("archive_admissions")[1]["artifact_size"] = package.fetch("size")
      end,
      "stale-candidate-identity" => lambda do |item|
        item[:installations]["openclaw"]["candidate_sha"] = "c" * 40
        rebind_installation_record!(item, 1, "openclaw")
      end,
      "tampered-gateway-bytes" => lambda do |item|
        gateway = item[:installations].fetch("candidate").fetch("required_roles").fetch("audit_gateway")
        gateway["sha256"] = DIGEST
        inventory = item[:installations].fetch("candidate").fetch("inventory")
        inventory.find { |record| record["path"] == gateway["path"] }["sha256"] = DIGEST
        refresh_installation!(item[:installations].fetch("candidate"))
        item[:receipt].fetch("gateway")["identity"] = deep_dup(gateway)
      end,
      "record-bytes-mismatch" => lambda do |item|
        record = item[:bundle_records].fetch(0)
        record["sha256"] = DIGEST
        record["size"] += 1
        item[:receipt].fetch("installed_manifests")[0] = deep_dup(record)
      end,
      "primary-record-cross-binding" => lambda do |item|
        record = item[:bundle_records].fetch(0)
        record["sha256"] = DIGEST
        item[:receipt].fetch("installed_manifests")[0] = deep_dup(record)
      end,
      "stale-execution-receipt-bytes" => lambda do |item|
        item[:receipt].fetch("run")["correlation_id"] = "different-run"
        item[:receipt].fetch("containment")["owner_correlation_id"] = "different-run"
      end,
      "execution-receipt-size-mismatch" => lambda do |item|
        record = item[:bundle_records].fetch(2)
        record["size"] += 1
        item[:row].fetch("evidence_bundle")[2] = deep_dup(record)
      end,
      "zero-byte-openclaw-package-and-archive" => lambda do |item|
        document = item[:installations].fetch("openclaw")
        package = document.fetch("required_roles").fetch("package")
        package["size"] = 0
        document.fetch("inventory").find { |entry| entry["path"] == package["path"] }["size"] = 0
        refresh_installation!(document)
        rebind_installation_record!(item, 1, "openclaw")
        item[:receipt].fetch("archive_admissions")[1]["artifact_size"] = 0
      end
    }

    accepted = cases.filter_map do |label, mutation|
      invalid = valid_fixture
      mutation.call(invalid)
      validate_execution(invalid)
      label
    rescue CREATOR::Error
      nil
    end
    assert_empty accepted, "execution admitted unbound cases: #{accepted.join(', ')}"
  end

  def test_primary_installation_and_execution_reject_unsafe_relative_paths
    unsafe_paths = [
      "", ".", "..", "/absolute", "../escape", "dir/../escape", "./file",
      "dir//file", "dir/", "C:/escape", "C:relative", "C:\\escape", "dir\\escape",
      "nul\0path", "\xFF".b
    ]

    unsafe_paths.each do |path|
      primary = valid_fixture
      primary.fetch(:row).fetch("created_files").first["path"] = path
      assert_raises(CREATOR::Error, "primary #{path.inspect}") { validate_primary(primary) }

      installed = valid_fixture
      document = installed.fetch(:installations).fetch("openclaw")
      dependency = document.fetch("inventory").last
      dependency["path"] = path
      begin
        refresh_installation!(document)
      rescue CREATOR::Error
        nil
      end
      assert_raises(CREATOR::Error, "installation #{path.inspect}") do
        CREATOR.validate_installation!(document:, kind: "openclaw",
                                       manifest: installed.fetch(:manifest), candidate_sha: SHA)
      end

      execution = valid_fixture
      execution.fetch(:row).fetch("executed_instruction")["path"] = path
      execution.fetch(:receipt)["authored_instruction"]["path"] = path
      execution.fetch(:receipt)["executed_instruction"]["path"] = path
      assert_raises(CREATOR::Error, "execution #{path.inspect}") { validate_execution(execution) }
    end
  end

  def test_schema_v1_vocabulary_is_bound_to_the_incumbent_proof
    require_relative "../../../packaging/live_agent_skills/proof"
    keys = %w[schema_version request prompt task_request task_key task_slug task_prompt task_new_argv commands files]
    constants = %i[
      SCHEMA_VERSION WORKFLOW_CREATOR_REQUEST WORKFLOW_CREATOR_PROMPT WORKFLOW_CREATOR_TASK_REQUEST
      WORKFLOW_CREATOR_TASK_KEY WORKFLOW_CREATOR_TASK_SLUG WORKFLOW_CREATOR_TASK_PROMPT
      WORKFLOW_CREATOR_TASK_NEW_ARGV WORKFLOW_CREATOR_COMMANDS WORKFLOW_CREATOR_FILES]
    keys.zip(constants).each do |key, name|
      assert_equal HiveLiveAgentProof.const_get(name), vocabulary.fetch(key), key
    end
    assert_equal({ "kind" => HiveLiveAgentProof::NATIVE_ACTIVATION_KINDS.fetch("openclaw"),
                   "invocation" => HiveLiveAgentProof::INVOCATIONS.fetch("openclaw") },
                 vocabulary.fetch("native_activation"))
    patterns = CREATOR.const_get(:Primitives, false).const_get(:SECRET_PATTERNS, false)
    assert_equal HiveLiveAgentProof::SECRET_PATTERNS.map(&:source), patterns.map(&:source)
  end

  def test_core_loads_cleanly_in_both_proof_orders_and_has_pure_dependencies
    core = "packaging/live_agent_skills/workflow_creator"
    proof = "packaging/live_agent_skills/proof"
    [ [ core ], [ core, proof ], [ proof, core ] ].each do |order|
      script = order.map { |feature| "require #{feature.dump}" }.join("\n")
      script << "\n"
      script << <<~RUBY
        names = HiveLiveAgentProof.constants(false).map(&:to_s)
        forbidden = (names & %w[SCHEMA_VERSION SAFE_SHA SECRET_PATTERNS Error]) + names.grep(/\\AWORKFLOW_CREATOR_/)
        if #{order == [ core ]} && !forbidden.empty?
          abort "forbidden root constant"
        end
        abort "missing facade" unless defined?(HiveLiveAgentProof::WorkflowCreator)
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I#{ROOT}", "-e", script)
      assert status.success?, "#{order.join(' -> ')}: #{out}#{err}"
      assert_empty err, order.join(" -> ")
      next unless order == [ core ]

      poisoned = script.sub("names = ", "HiveLiveAgentProof::WORKFLOW_CREATOR_POISON = true\nnames = ")
      poison_out, poison_err, poison_status = Open3.capture3(
        RbConfig.ruby, "-w", "-I#{ROOT}", "-e", poisoned
      )
      refute poison_status.success?, "root constant poison was not detected: #{poison_out}#{poison_err}"
      assert_includes poison_err, "forbidden root constant"
    end
    %i[Primitives Contract ExecutionContract].each do |name|
      assert_raises(NameError) { eval("HiveLiveAgentProof::WorkflowCreator::#{name}") }
    end
    sources = %w[
      proof_primitives.rb workflow_creator.rb workflow_creator_contract.rb
      workflow_creator_execution_contract.rb
    ].to_h do |name|
      [ name, File.read(File.join(ROOT, "packaging", "live_agent_skills", name)) ]
    end
    sources.each do |name, source|
      refute_match(/require_relative ["'](?:proof|workflow_creator_bundle)["']/, source, name)
    end
    assert_match(/require_relative "proof_primitives"/, sources.fetch("workflow_creator.rb"))
    assert_match(/require_relative "workflow_creator_contract"/, sources.fetch("workflow_creator.rb"))
    assert_match(/require_relative "workflow_creator_execution_contract"/, sources.fetch("workflow_creator.rb"))
    assert_pure_source_surface(sources)
    poisoned = sources.merge(
      "proof_primitives.rb" => "#{sources.fetch('proof_primitives.rb')}\ndef dormant_io\n  require 'socket'\n  TCPSocket.open('localhost', 9)\nend\n"
    )
    assert_raises(Minitest::Assertion) { assert_pure_source_surface(poisoned) }
  end

  def test_production_files_stay_inside_r43_line_method_and_branch_budgets
    caps = {
      "proof_primitives.rb" => { lines: 80 },
      "workflow_creator.rb" => { lines: 110 },
      "workflow_creator_contract.rb" => { lines: 220, methods: 10, branches: 12 },
      "workflow_creator_execution_contract.rb" => { lines: 180, methods: 8, branches: 10 }
    }
    observed = caps.to_h do |name, limits|
      source = File.read(File.join(ROOT, "packaging", "live_agent_skills", name))
      counts = {
        lines: source.lines.length,
        methods: source.scan(/^\s*def\b/).length,
        branches: coverage_branch_sites(name)
      }
      limits.each do |metric, limit|
        assert_operator counts.fetch(metric), :<=, limit, "#{name} #{metric}"
      end
      [ name, counts ]
    end
    totals = observed.values.each_with_object(Hash.new(0)) do |counts, sum|
      counts.each { |metric, value| sum[metric] += value }
    end
    { lines: 590, methods: 22, branches: 28 }.each do |metric, hard_limit|
      assert_operator totals.fetch(metric), :<=, hard_limit, "aggregate hard #{metric}"
    end
    { lines: 588, methods: 22, branches: 19 }.each do |metric, target|
      assert_operator totals.fetch(metric), :<=, target, "aggregate target #{metric}"
    end
  end

  private

  def deep_dup(value)
    Marshal.load(Marshal.dump(value))
  end

  def secret_shape
    %w[sk ant abcdefghijklmnopqrstuvwxyz].join("-")
  end

  def coverage_branch_sites(name)
    path = File.join(ROOT, "packaging", "live_agent_skills", name)
    script = <<~'RUBY'
      require "coverage"
      Coverage.start(branches: true)
      path = File.expand_path(ARGV.fetch(0))
      load path
      puts Coverage.peek_result.fetch(path).fetch(:branches).length
    RUBY
    clean_env = %w[HIVE_COVERAGE HIVE_COVERAGE_ROOT HIVE_COVERAGE_RUN_ID RUBYOPT].to_h do |key|
      [ key, nil ]
    end
    out, err, status = Open3.capture3(clean_env, RbConfig.ruby, "-e", script, path)
    assert status.success?, "#{name} branch coverage: #{out}#{err}"
    assert_empty err, name
    Integer(out, 10)
  end

  def valid_fixture
    manifest = artifact_manifest
    installations = {
      "candidate" => installation("candidate", manifest),
      "openclaw" => installation("openclaw", manifest)
    }
    records = bundle_records(installations)
    row = primary_row(manifest, records)
    receipt = execution_receipt(row, records, installations)
    bind_execution_record!(row, records, receipt)
    {
      manifest:, bundle_records: records, installations:, row:, receipt:,
      receipt_sha256: records.fetch(2).fetch("sha256")
    }
  end

  def validate_primary(fixture)
    CREATOR.validate_primary!(
      row: fixture.fetch(:row), manifest: fixture.fetch(:manifest),
      candidate_sha: SHA, bundle_records: fixture.fetch(:bundle_records)
    )
  end

  def validate_execution(fixture)
    CREATOR.validate_execution!(
      receipt: fixture.fetch(:receipt), row: fixture.fetch(:row), candidate_sha: SHA,
      installation_records: fixture.fetch(:bundle_records).first(2),
      receipt_sha256: fixture.fetch(:receipt_sha256), manifest: fixture.fetch(:manifest),
      candidate_installation: fixture.fetch(:installations).fetch("candidate"),
      openclaw_installation: fixture.fetch(:installations).fetch("openclaw")
    )
  end

  def artifact_manifest
    version = "1.2.3"
    names = [
      "hive-agent-skills-#{SHA}.tar.gz", "hive-cli-#{version}.gem",
      "hive-source-#{SHA}.tar.gz"
    ]
    {
      "schema" => "hive-live-agent-candidate-artifacts", "schema_version" => 1,
      "candidate_sha" => SHA, "hive_version" => version,
      "skill_version" => "2026.8.2", "canonical_digest" => Digest::SHA256.hexdigest("canonical"),
      "files" => names.sort.to_h do |name|
        [ name, { "sha256" => Digest::SHA256.hexdigest(name), "size" => name.bytesize } ]
      end
    }
  end

  def bundle_records(installations)
    documents = [ installations.fetch("candidate"), installations.fetch("openclaw") ]
    %w[candidate-installed-manifest.json openclaw-installed-manifest.json].each_with_index.map do |path, index|
      bytes = CREATOR.canonical_json(documents.fetch(index))
      {
        "kind" => %w[candidate_installation openclaw_installation execution_receipt].fetch(index),
        "path" => path, "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize
      }
    end << {
      "kind" => "execution_receipt", "path" => "execution-receipt.json",
      "sha256" => Digest::SHA256.hexdigest("execution-receipt.json"), "size" => 22
    }
  end

  def rebind_installation_record!(fixture, index, kind)
    bytes = CREATOR.canonical_json(fixture.fetch(:installations).fetch(kind))
    record = fixture.fetch(:bundle_records).fetch(index)
    record["sha256"] = Digest::SHA256.hexdigest(bytes)
    record["size"] = bytes.bytesize
    fixture.fetch(:row).fetch("evidence_bundle")[index] = deep_dup(record)
    fixture.fetch(:receipt).fetch("installed_manifests")[index] = deep_dup(record)
  end

  def bind_execution_record!(row, records, receipt)
    bytes = CREATOR.canonical_json(receipt)
    record = records.fetch(2)
    record["sha256"] = Digest::SHA256.hexdigest(bytes)
    record["size"] = bytes.bytesize
    row.fetch("evidence_bundle")[2] = deep_dup(record)
    summary = { "status" => "passed", "receipt_sha256" => record.fetch("sha256") }
    %w[containment teardown cleanup].each { |field| row[field] = deep_dup(summary) }
  end

  def rebind_execution_receipt!(fixture)
    bind_execution_record!(fixture.fetch(:row), fixture.fetch(:bundle_records), fixture.fetch(:receipt))
    fixture[:receipt_sha256] = fixture.fetch(:bundle_records).fetch(2).fetch("sha256")
  end

  def refresh_installation!(document)
    closure = {
      "required_roles" => document.fetch("required_roles"),
      "inventory" => document.fetch("inventory")
    }
    document["closure_sha256"] = Digest::SHA256.hexdigest(CREATOR.canonical_json(closure))
    document["total_size"] = document.fetch("inventory").sum { |record| record.fetch("size") }
  end

  def assert_pure_source_surface(sources)
    script = "require 'json'; require 'digest'; before=$LOADED_FEATURES.dup; " \
      "require 'packaging/live_agent_skills/workflow_creator'; puts(($LOADED_FEATURES-before).join(\"\\n\"))"
    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{ROOT}", "-e", script)
    assert status.success?, err
    allowed = %r{\A#{Regexp.escape(ROOT)}/packaging/live_agent_skills/(?:proof_primitives|workflow_creator(?:_contract|_execution_contract)?)\.rb\z|/(?:digest/sha2(?:/loader)?\.rb|digest/sha2\.[^/]+)\z}
    assert out.lines.map(&:chomp).all? { |path| allowed.match?(path) }, out
    expected = {
      "proof_primitives.rb" => {
        requires: [ %w[require json] ],
        calls: %w[
          ascii_only? bit_length bytebegin byteend bytesize byteslice call class count deep_freeze dup each
          each_with_index each_with_object empty? encode encoding escape fetch filter_map finite? first
          force_encoding freeze include? instance_of? is_a? keys lambda last last_match length map match?
          max module_function none? pretty_generate raise require scan scrub sort sort_by! source split
          start_with? tap then to_h to_s valid_encoding?
        ],
        constants: %w[
          ArgumentError Array Encoding EncodingError Error FalseClass Float GeneratorError Hash HiveLiveAgentProof
          Integer JSON MAX_JSON_BYTES MAX_JSON_DEPTH MAX_JSON_INTEGER_BITS MAX_JSON_NODES NestingError NilClass Primitives Regexp
          SECRET_PATTERNS StandardError String TrueClass TypeError UTF_8 WorkflowCreator
        ]
      },
      "workflow_creator.rb" => {
        requires: [ %w[require digest], %w[require_relative proof_primitives],
                    %w[require_relative workflow_creator_contract],
                    %w[require_relative workflow_creator_execution_contract] ],
        calls: %w[
          canonical_json deep_freeze failure fetch hexdigest private_constant require require_relative
          validate! validate_installation! validate_nonpassing! validate_primary!
        ],
        constants: %w[
          Contract Digest ExecutionContract HiveLiveAgentProof Primitives SHA256 Vocabulary WorkflowCreator
        ]
      },
      "workflow_creator_contract.rb" => {
        requires: [ %w[require digest], %w[require_relative proof_primitives] ],
        calls: %w[
          all? between? bytesize call canonical_json deep_freeze dig downcase drop each each_with_index empty? encoding
          exact_secrets! fetch find first freeze generate hexdigest include? instance_of? keys lambda length map match?
          module_function nil? one? positive? raise require require_relative safe_relative_path? secret_findings
          secret_safe_text select sort sum then uniq valid_encoding? valid_manifest? validate_nonpassing!
          values values_at zero? zip
        ],
        constants: %w[
          ARTIFACT_KEYS ASSERT ArgumentError Array BUNDLE_KEYS CLASSIFICATIONS Contract DETAIL_LIMIT DIGEST Digest Encoding EncodingError Error
          FAILURE_KEYS FAILURE_PART FILE_KEYS GeneratorError Hash HiveLiveAgentProof INSTALLATION_KEYS Integer JSON
          KeyError MANIFEST_KEYS MAX_DETAIL_INPUT_BYTES MAX_EXACT_SECRETS MAX_INVENTORY_ENTRIES MAX_MEMBER_BYTES MAX_SECRET_BYTES
          MAX_TOTAL_BYTES NoMethodError PRIMARY_KEYS Primitives SHA SHA256 SUMMARY_KEYS String TypeError UTF_8 Vocabulary
          WorkflowCreator
        ]
      },
      "workflow_creator_execution_contract.rb" => {
        requires: [ %w[require_relative workflow_creator_contract] ],
        calls: %w[
          all? between? bytesize call canonical_json deep_freeze each_with_index empty? fetch first freeze generate
          hexdigest include? instance_of? keys lambda length map match? module_function nil? positive? raise require_relative
          safe_relative_path? secret_findings slice sort uniq valid_process? validate_aggregates! validate_identity!
          validate_installation! validate_primary! validate_processes! values_at zero? zip
        ],
        constants: %w[
          ARCHIVE_KEYS ASSERT ArgumentError Array BUNDLE_KEYS CAPTURE_KEYS CLEANUP_KEYS COMMAND_KEYS CONTAINMENT_KEYS
          Contract DIGEST Digest EncodingError Error ExecutionContract FILE_KEYS GATEWAY_KEYS GeneratorError Hash HiveLiveAgentProof
          Integer JSON KEYS KeyError LABEL MAX_ARCHIVE_BYTES MAX_ARCHIVE_ENTRIES MAX_CAPTURE_BYTES NoMethodError
          OUTER_KEYS PROCESS_TEARDOWN_KEYS Primitives RUN_KEYS SHA SHA256 String TARGET_KEYS TEARDOWN_KEYS TypeError
          Vocabulary WorkflowCreator
        ]
      }
    }
    sources.each do |name, source|
      syntax = Ripper.sexp(source)
      refute_nil syntax, name
      nodes = []
      walk = lambda do |node|
        next unless node.is_a?(Array)
        nodes << node
        node.each { |child| walk.call(child) }
      end
      walk.call(syntax)
      calls = nodes.filter_map do |node|
        case node.first
        when :vcall, :fcall, :command then node.dig(1, 1)
        when :call, :command_call, :field then node.dig(3, 1)
        end
      end
      requires = nodes.filter_map do |node|
        invocation, arguments = case node.first
        when :command then [ node[1], node[2] ]
        when :command_call then [ node[3], node[4] ]
        when :method_add_arg
          call = node[1]
          [ call&.first == :fcall ? call[1] : call&.[](3), node[2] ]
        end
        next unless invocation && %w[require require_relative].include?(invocation[1])
        parts = []
        dynamic = false
        inspect_argument = lambda do |argument|
          next unless argument.is_a?(Array)
          parts << argument[1] if argument.first == :@tstring_content
          dynamic = true if argument.first == :string_embexpr
          argument.each { |child| inspect_argument.call(child) }
        end
        inspect_argument.call(arguments)
        [ invocation[1], !dynamic && parts.one? ? parts.first : "<dynamic>" ]
      end
      expected_surface = expected.fetch(name)
      assert_equal calls.count { |call| %w[require require_relative].include?(call) }, requires.length, name
      assert_equal expected_surface.fetch(:requires), requires, name
      assert_equal expected_surface.fetch(:calls), calls.uniq.sort, name
      tokens = Ripper.lex(source)
      constants = tokens.filter_map { |_position, type, text| text if type == :on_const }.uniq.sort
      assert_equal expected_surface.fetch(:constants), constants, name
      assert_empty tokens.select { |_position, type, _text| %i[on_backtick on_gvar].include?(type) }, name
    end
  end

  def installation(kind, manifest)
    roles = vocabulary.fetch("member_roles").fetch(kind).to_h do |role|
      path = if role == "package"
        kind == "candidate" ? "packages/hive-cli-1.2.3.gem" : "packages/openclaw.tgz"
      else
        "#{role}/fixture"
      end
      artifact = manifest.fetch("files").fetch("hive-cli-1.2.3.gem") if kind == "candidate" && role == "package"
      [
        role,
        {
          "path" => path,
          "sha256" => artifact&.fetch("sha256") || Digest::SHA256.hexdigest(path),
          "size" => artifact&.fetch("size") || path.bytesize
        }
      ]
    end
    dependency = {
      "path" => "runtime/dependency.rb", "sha256" => Digest::SHA256.hexdigest("runtime/dependency.rb"),
      "size" => 21
    }
    inventory = [ *roles.values.map { |record| deep_dup(record) }, dependency ].sort_by { |record| record.fetch("path") }
    closure = { "required_roles" => roles, "inventory" => inventory }
    {
      "schema" => vocabulary.fetch("installed_schema"), "schema_version" => 1,
      "candidate_sha" => SHA, "kind" => kind,
      "version" => kind == "candidate" ? manifest.fetch("hive_version") : "fixture-openclaw",
      "closure_sha256" => Digest::SHA256.hexdigest(CREATOR.canonical_json(closure)),
      "required_roles" => roles, "inventory" => inventory,
      "total_size" => inventory.sum { |record| record.fetch("size") },
      "secret_scan" => { "status" => "passed", "scanner" => vocabulary.fetch("scanner") }
    }
  end

  def primary_row(manifest, records)
    created = expected_files.map do |path|
      { "path" => path, "sha256" => Digest::SHA256.hexdigest(path), "size" => path.bytesize }
    end
    instruction = deep_dup(created.fetch(2))
    summary = { "status" => "passed", "receipt_sha256" => records.fetch(2).fetch("sha256") }
    {
      "schema" => vocabulary.fetch("evidence_schema"), "schema_version" => 1,
      "platform" => "openclaw", "candidate_sha" => SHA, "result" => "passed",
      "prompt_sha256" => Digest::SHA256.hexdigest(expected_prompt),
      "task_prompt_sha256" => Digest::SHA256.hexdigest(expected_task_prompt),
      "skill" => {
        "skill_version" => manifest.fetch("skill_version"),
        "canonical_digest" => manifest.fetch("canonical_digest")
      },
      "native_activation" => deep_dup(vocabulary.fetch("native_activation")),
      "hive_commands" => deep_dup(expected_commands), "created_files" => created,
      "validation" => deep_dup(expected_graph), "creation_only_task_count" => 0,
      "task_count" => 1, "task" => deep_dup(expected_task), "external_actions" => [],
      "secret_scan" => { "status" => "passed", "scanner" => vocabulary.fetch("scanner") },
      "execution_kind" => "authenticated_openclaw", "model_loop" => "executed",
      "executed_instruction" => instruction, "evidence_bundle" => deep_dup(records),
      "containment" => deep_dup(summary), "teardown" => deep_dup(summary), "cleanup" => deep_dup(summary)
    }
  end

  def execution_receipt(row, records, installations)
    command_labels = expected_commands.each_index.map { |index| format("command-%02d", index + 1) }
    commands = expected_commands.each_with_index.map do |argv, index|
      process_receipt("attempt_label" => command_labels.fetch(index)).merge(
        "position" => index + 1, "argv" => deep_dup(argv)
      )
    end
    outer = vocabulary.fetch("outer_roles").each_with_index.map do |identity, index|
      process_receipt("label" => %w[outer-workflow-creator outer-authorized-work].fetch(index)).merge(
        deep_dup(identity), "argv_sha256" => Digest::SHA256.hexdigest("outer-argv-#{index}")
      )
    end
    labels = command_labels + outer.map { |process| process.fetch("label") }
    correlation = "workflow-creator-proof-run"
    packages = installations.values.map { |document| document.dig("required_roles", "package") }
    archives = packages.each_with_index.map do |package, index|
      {
        "label" => vocabulary.fetch("archive_labels").fetch(index),
        "artifact_sha256" => package.fetch("sha256"), "artifact_size" => package.fetch("size"),
        "policy_sha256" => vocabulary.fetch("archive_policy_sha256"),
        "entry_count" => 5, "uncompressed_bytes" => 1_024, "status" => "passed"
      }
    end
    instruction = deep_dup(row.fetch("executed_instruction"))
    {
      "schema" => vocabulary.fetch("execution_schema"), "schema_version" => 1,
      "candidate_sha" => SHA, "result" => "passed", "execution_plan" => vocabulary.fetch("execution_plan"),
      "classification" => {
        "outer" => deep_dup(vocabulary.fetch("classification")),
        "nested_stage" => { "execution_kind" => "deterministic_fixture", "model_loop" => "not_exercised" }
      },
      "installed_manifests" => deep_dup(records.first(2)),
      "run" => { "correlation_id" => correlation, "expected_labels" => labels },
      "gateway" => {
        "identity" => deep_dup(installations.fetch("candidate").dig("required_roles", "audit_gateway")),
        "command_labels" => command_labels, "status" => "passed"
      },
      "archive_admissions" => archives, "commands" => commands, "outer_processes" => outer,
      "authored_instruction" => deep_dup(instruction), "executed_instruction" => deep_dup(instruction),
      "external_actions" => [],
      "containment" => {
        "status" => "passed", "mechanism" => "supervised-process-tree",
        "established_before_launch" => true, "owner_correlation_id" => correlation,
        "root_loss_behavior" => "fail-closed"
      },
      "teardown" => {
        "status" => "passed", "expected_labels" => labels, "receipt_labels" => deep_dup(labels),
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
      "secret_scan" => { "status" => "passed", "scanner" => vocabulary.fetch("scanner") }
    }
  end

  def process_receipt(label)
    label.merge(
      "exit_code" => 0, "signal" => nil, "completed" => true,
      "capture" => {
        "limit_bytes" => 4_096, "stdout_bytes" => 0, "stderr_bytes" => 0,
        "stdout_sha256" => Digest::SHA256.hexdigest(""), "stderr_sha256" => Digest::SHA256.hexdigest(""),
        "stdout_truncated" => false, "stderr_truncated" => false,
        "secret_scan" => { "status" => "passed", "scanner" => vocabulary.fetch("scanner") }
      },
      "teardown" => {
        "status" => "passed", "term_sent" => false, "kill_sent" => false,
        "reaped" => true, "descendants" => "none", "owner_complete" => true
      }
    )
  end

  def vocabulary
    CREATOR::Vocabulary
  end

  def expected_prompt
    <<~PROMPT
      /hive
      Create a three-stage editorial workflow that researches, drafts, and requires approval before publishing.
      Use the installed Hive workflow-creator capability in this initialized project.
      This is creation-only: validate the result, report the defaults, and do not create or run a task.
    PROMPT
  end

  def expected_task_prompt
    <<~PROMPT
      /hive
      Use the validated editorial workflow to create and run one task for:
      "Research and draft the launch announcement for approval."
      Use idempotency key workflow-creator-proof:editorial:live-proof. In this exact order: create the task,
      run its first stage once, repeat the same creation command once to prove the retry is a no-op,
      then query operational status. Do not publish or perform any other external action.
    PROMPT
  end

  def expected_commands
    task_argv = [
      "new", "workflow-creator-proof", "--workflow", "editorial",
      "--idempotency-key", "workflow-creator-proof:editorial:live-proof",
      "--json", "Research and draft the launch announcement for approval."
    ]
    [
      [ "version" ],
      [ "workflow", "list", "--json" ],
      [ "workflow", "new", "editorial", "--json" ],
      [ "workflow", "validate", "editorial", "--json" ],
      [ "workflow", "commit", "editorial" ],
      task_argv,
      [ "run", "editorial-live-proof" ],
      task_argv,
      [ "status", "--operational", "--json" ]
    ]
  end

  def expected_files
    %w[
      .hive-state/workflows/editorial.yml
      .hive-state/workflows/editorial/draft.md
      .hive-state/workflows/editorial/research.md
    ]
  end

  def expected_graph
    {
      "valid" => true,
      "stages" => %w[research draft approval],
      "automatic_edges" => [ %w[research draft], %w[draft approval] ],
      "human_outcomes" => [
        { "stage" => "approval", "name" => "approve", "complete" => true,
          "artifact" => "draft.md", "to" => nil },
        { "stage" => "approval", "name" => "reject", "complete" => false,
          "artifact" => nil, "to" => "draft" }
      ]
    }
  end

  def expected_task
    {
      "slug" => "editorial-live-proof", "workflow" => "editorial",
      "first_created" => true, "retry_created" => false,
      "run_count" => 1, "current_stage" => "1-research"
    }
  end
end
