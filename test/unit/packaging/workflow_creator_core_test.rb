require "test_helper"
require "digest"
require "json"
require "open3"
require "rbconfig"
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

  def test_core_loads_cleanly_in_both_proof_orders_and_has_no_io_or_back_edge
    core = "packaging/live_agent_skills/workflow_creator"
    proof = "packaging/live_agent_skills/proof"
    [ [ core ], [ core, proof ], [ proof, core ] ].each do |order|
      script = order.map { |feature| "require #{feature.dump}" }.join("\n")
      script << "\n"
      script << <<~RUBY
        names = HiveLiveAgentProof.constants(false).map(&:to_s)
        forbidden = (names & %w[SCHEMA_VERSION SAFE_SHA SECRET_PATTERNS Error]) + names.grep(/\AWORKFLOW_CREATOR_/)
        if #{order == [ core ]} && !forbidden.empty?
          abort "forbidden root constant"
        end
        abort "missing facade" unless defined?(HiveLiveAgentProof::WorkflowCreator)
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I#{ROOT}", "-e", script)
      assert status.success?, "#{order.join(' -> ')}: #{out}#{err}"
      assert_empty err, order.join(" -> ")
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
      refute_match(/\b(?:File|Dir|IO|Open3|Process|Pathname|Zlib|Gem::Package)\b|`|\bsystem\s*\(/,
                   source, name)
      refute_match(/require_relative ["'](?:proof|workflow_creator_bundle)["']/, source, name)
    end
    assert_match(/require_relative "proof_primitives"/, sources.fetch("workflow_creator.rb"))
    assert_match(/require_relative "workflow_creator_contract"/, sources.fetch("workflow_creator.rb"))
    assert_match(/require_relative "workflow_creator_execution_contract"/, sources.fetch("workflow_creator.rb"))
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
    { lines: 576, methods: 21, branches: 27 }.each do |metric, target|
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
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, path)
    assert status.success?, "#{name} branch coverage: #{out}#{err}"
    assert_empty err, name
    Integer(out, 10)
  end

  def valid_fixture
    manifest = artifact_manifest
    records = bundle_records
    installations = {
      "candidate" => installation("candidate", manifest),
      "openclaw" => installation("openclaw", manifest)
    }
    row = primary_row(manifest, records)
    receipt = execution_receipt(row, records, installations)
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
      receipt_sha256: fixture.fetch(:receipt_sha256),
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

  def bundle_records
    %w[
      candidate-installed-manifest.json openclaw-installed-manifest.json
      execution-receipt.json
    ].each_with_index.map do |path, index|
      {
        "kind" => %w[candidate_installation openclaw_installation execution_receipt].fetch(index),
        "path" => path, "sha256" => Digest::SHA256.hexdigest(path), "size" => path.bytesize
      }
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
