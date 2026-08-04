require "test_helper"
require "bundler"
require "digest"
require "open3"
require "rbconfig"
require "ripper"
require "tmpdir"
require "yaml"

require_relative "../../../packaging/live_agent_skills/workflow_creator"

class WorkflowCreatorCoreTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SHA = "a" * 40
  DIGEST = "b" * 64
  TASK_SLUG = "research-and-draft-the-launch-260804-ab12"
  Creator = HiveLiveAgentProof::WorkflowCreator
  Values = Creator::Values
  SOURCES = %w[
    workflow_creator.rb workflow_creator_contract.rb workflow_creator_execution_contract.rb
  ].to_h { |name| [ name, File.join(ROOT, "packaging", "live_agent_skills", name) ] }.freeze
  POISONED_CHILD_ENV = %w[HIVE_COVERAGE HIVE_COVERAGE_ROOT HIVE_COVERAGE_RUN_ID RUBYOPT]
    .to_h { |name| [ name, nil ] }.freeze
  DECISIONS = %i[
    if unless elsif if_mod unless_mod ifop when in rescue rescue_mod while until for while_mod until_mod
  ].freeze

  def test_public_api_and_vocabulary_are_exact_and_deeply_frozen
    assert_equal %i[
      commands_for failure validate_execution! validate_installation! validate_nonpassing! validate_primary!
    ], Creator.singleton_methods(false).sort
    assert Creator::Error < StandardError
    assert_equal %w[
      schema_version evidence_schema installed_schema execution_schema execution_plan scanner
      request prompt task_request task_key task_slug task_prompt task_new_argv command_labels commands
      task_slug_binding files
      executed_instruction native_activation graph task classification bundle_files member_roles
      outer_roles archive_labels archive_policy_sha256 cleanup_labels
    ], Creator::Vocabulary.keys
    assert_equal 1, Creator::Vocabulary.fetch("schema_version")
    assert_equal "hive-live-workflow-creator-evidence", Creator::Vocabulary.fetch("evidence_schema")
    assert_equal "hive-live-workflow-creator-installed-manifest", Creator::Vocabulary.fetch("installed_schema")
    assert_equal "hive-live-workflow-creator-execution-receipt", Creator::Vocabulary.fetch("execution_schema")
    assert_equal [ "run", "{created_slug}" ], Creator::Vocabulary.fetch("commands").fetch(6)
    assert_equal TASK_SLUG, Creator.commands_for(task_slug: TASK_SLUG).value.fetch(6).fetch(1)
    assert_equal({ "source_position" => 6, "source_result_field" => "slug",
                   "target_position" => 7, "target_argument" => 1, "template" => "{created_slug}" },
                 Creator::Vocabulary.fetch("task_slug_binding"))
    assert_deeply_frozen(Creator::Vocabulary)
  end

  def test_failure_is_total_at_detail_work_ceiling_and_returns_an_owned_snapshot
    secret = "exact-boundary-secret"
    detail = "x" * 980 + secret
    detail << "y" * (4_096 - detail.bytesize)
    at_limit = Creator.failure(
      candidate_sha: SHA, phase: "preflight", reason: "provider_unavailable",
      detail:, exact_secrets: [ secret ]
    )
    assert_snapshot(at_limit)
    assert_includes at_limit.value.fetch("detail"), "[REDACTED]"
    refute_includes at_limit.value.fetch("detail"), secret
    assert_operator at_limit.value.fetch("detail").bytesize, :<=, 1_000

    [ "x" * 4_097, "x" * 300_000 ].each do |detail|
      omitted = Creator.failure(
        candidate_sha: SHA, phase: "preflight", reason: "provider_unavailable", detail:
      )
      assert_snapshot(omitted)
      assert_equal "[detail omitted: unsafe or oversized]", omitted.value.fetch("detail")
    end

    invalid = deep_dup(at_limit.value)
    invalid["phase"] = 1
    assert_raises(Creator::Error) { Creator.validate_nonpassing!(invalid) }
  end

  def test_public_validation_captures_each_caller_value_once_and_never_dispatches_to_it_later
    fixture = valid_fixture
    raw = [ fixture.fetch(:row), fixture.fetch(:manifest), SHA, fixture.fetch(:bundle_records) ]
    captured_ids = []
    trace = TracePoint.new(:call) do |event|
      next unless event.defined_class == Values.singleton_class && event.method_id == :capture
      captured_ids << event.binding.local_variable_get(:input).object_id
    end
    result = trace.enable do
      Creator.validate_primary!(
        row: raw.fetch(0), manifest: raw.fetch(1), candidate_sha: raw.fetch(2), bundle_records: raw.fetch(3)
      )
    end
    raw.each { |value| assert_equal 1, captured_ids.count(value.object_id) }
    assert_snapshot(result)
    assert_equal fixture.fetch(:row), result.value
    refute_same fixture.fetch(:row), result.value

    fixture = valid_fixture
    poison(fixture.fetch(:row), :keys, :fetch, :[], :dig)
    poison(fixture.fetch(:manifest), :keys, :fetch, :[])
    poison(fixture.fetch(:bundle_records), :each, :length, :fetch, :[])
    assert_snapshot(validate_primary(fixture))
  end

  def test_failure_uses_caller_once_captures_then_one_internal_result_capture
    detail = +"diagnostic"
    capture_inputs = []
    trace = TracePoint.new(:call) do |event|
      next unless event.defined_class == Values.singleton_class && event.method_id == :capture
      capture_inputs << event.binding.local_variable_get(:input)
    end
    result = trace.enable do
      Creator.failure(candidate_sha: SHA, phase: "preflight", reason: "not_started", detail:)
    end
    assert_equal 3, capture_inputs.length
    assert_same detail, capture_inputs.fetch(1)
    assert capture_inputs.fetch(0).instance_of?(Hash), "first capture is the stable caller-input envelope"
    assert capture_inputs.fetch(2).instance_of?(Hash), "last capture is the internally constructed result"
    refute_same capture_inputs.fetch(0), capture_inputs.fetch(2)
    admitted = Creator.validate_nonpassing!(result.value)
    refute_same result, admitted
    assert_equal result.canonical_bytes, admitted.canonical_bytes
  end

  def test_primary_contract_is_exact_typed_ordered_and_bound
    fixture = valid_fixture
    assert_snapshot(validate_primary(fixture))
    mutations = {
      extra_key: ->(item) { item[:row]["unexpected"] = true },
      schema_float: ->(item) { item[:row]["schema_version"] = 1.0 },
      command_order: ->(item) { item[:row]["hive_commands"].reverse! },
      created_order: ->(item) { item[:row]["created_files"].reverse! },
      task_count_float: ->(item) { item[:row]["task_count"] = 1.0 },
      run_count_float: ->(item) { item[:row]["task"]["run_count"] = 1.0 },
      bundle_order: ->(item) { item[:row]["evidence_bundle"].reverse! },
      bundle_size_float: ->(item) { item[:bundle_records][0]["size"] = 12.0 },
      external_effect: ->(item) { item[:row]["external_actions"] << "publish" }
    }
    mutations.each do |label, mutate|
      invalid = valid_fixture
      mutate.call(invalid)
      assert_raises(Creator::Error, label.to_s) { validate_primary(invalid) }
    end
  end

  def test_installation_contract_is_exact_typed_ordered_and_manifest_bound
    fixture = valid_fixture
    fixture.fetch(:installations).each do |kind, document|
      result = Creator.validate_installation!(document:, kind:, manifest: fixture.fetch(:manifest), candidate_sha: SHA)
      assert_snapshot(result)
      assert_equal document, result.value
    end
    mutations = {
      schema_float: ->(item) { item[:document]["schema_version"] = 1.0 },
      inventory_order: ->(item) { item[:document]["inventory"].reverse! },
      inventory_size_float: ->(item) { item[:document]["inventory"][0]["size"] = 1.0 },
      required_roles_type: ->(item) { item[:document]["required_roles"] = [] },
      missing_role: ->(item) { item[:document]["required_roles"].delete("executable") },
      role_not_inventory: ->(item) { item[:document]["required_roles"]["executable"]["sha256"] = DIGEST },
      closure: ->(item) { item[:document]["closure_sha256"] = DIGEST },
      total_float: ->(item) { item[:document]["total_size"] = item[:document]["total_size"].to_f },
      package: ->(item) { item[:document]["required_roles"]["package"]["sha256"] = DIGEST }
    }
    mutations.each do |label, mutate|
      current = valid_fixture
      item = { document: current.fetch(:installations).fetch("candidate"), manifest: current.fetch(:manifest) }
      mutate.call(item)
      assert_raises(Creator::Error, label.to_s) do
        Creator.validate_installation!(document: item.fetch(:document), kind: "candidate",
                                       manifest: item.fetch(:manifest), candidate_sha: SHA)
      end
    end
  end

  def test_execution_contract_binds_order_numeric_types_capture_digests_and_aggregates
    fixture = valid_fixture
    assert_snapshot(validate_execution(fixture))
    mutations = {
      schema_float: ->(item) { item[:receipt]["schema_version"] = 1.0 },
      record_order: ->(item) { item[:receipt]["installed_manifests"].reverse! },
      installation_records_type: ->(item) { item[:installation_records] = {} },
      evidence_bundle_length: ->(item) { item[:row]["evidence_bundle"] = [] },
      command_order: ->(item) { item[:receipt]["commands"].reverse! },
      command_label: ->(item) { item[:receipt]["commands"][0]["attempt_label"] = "command-01" },
      task_slug_binding: ->(item) { item[:receipt]["task_slug_binding"]["value"] = "other-task-260804-ab12" },
      task_slug_source: ->(item) { item[:receipt]["task_slug_binding"]["source_position"] = 5 },
      position_float: ->(item) { item[:receipt]["commands"][0]["position"] = 1.0 },
      exit_float: ->(item) { item[:receipt]["commands"][0]["exit_code"] = 0.0 },
      teardown_float: ->(item) { item[:receipt]["teardown"]["remaining_descendants"] = 0.0 },
      capture_positive_empty_digest: lambda do |item|
        item[:receipt]["commands"][0]["capture"]["stdout_bytes"] = 1
      end,
      capture_bytes_type: ->(item) { item[:receipt]["commands"][0]["capture"]["stdout_bytes"] = "1" },
      capture_zero_nonempty_digest: lambda do |item|
        item[:receipt]["commands"][0]["capture"]["stdout_sha256"] = Digest::SHA256.hexdigest("x")
      end,
      truncated_short: lambda do |item|
        item[:receipt]["commands"][0]["capture"]["stdout_truncated"] = true
      end,
      instruction_binding: ->(item) { item[:receipt]["executed_instruction"]["sha256"] = DIGEST },
      receipt_digest: ->(item) { item[:receipt_sha256] = DIGEST }
    }
    mutations.each do |label, mutate|
      invalid = valid_fixture
      mutate.call(invalid)
      assert_raises(Creator::Error, label.to_s) { validate_execution(invalid) }
    end
  end

  def test_core_clean_loads_alone_and_co_loads_with_untouched_proof_in_both_orders
    scripts = [
      "require './packaging/live_agent_skills/workflow_creator'",
      "require './packaging/live_agent_skills/workflow_creator'; require './packaging/live_agent_skills/proof'",
      "require './packaging/live_agent_skills/proof'; require './packaging/live_agent_skills/workflow_creator'"
    ]
    scripts.each do |script|
      out, err, status = Bundler.with_unbundled_env do
        Open3.capture3(
          POISONED_CHILD_ENV, RbConfig.ruby, "--disable-gems", "-I#{ROOT}", "-e",
          "#{script}; puts HiveLiveAgentProof::WorkflowCreator::Vocabulary.fetch('schema_version')", chdir: ROOT
        )
      end
      assert status.success?, err
      assert_equal "1\n", out
    end
    SOURCES.each_value do |path|
      source = File.read(path)
      refute_match(/workflow_creator_bundle|release_candidate|proof\.rb/, source)
    end
  end

  def test_r43_source_metrics_and_explicit_method_overlay_stay_within_budget
    metrics = SOURCES.transform_values { |path| static_metrics(File.read(path)) }
    expected_caps = {
      "workflow_creator.rb" => [ 140, 7, 4 ],
      "workflow_creator_contract.rb" => [ 260, 15, 24 ],
      "workflow_creator_execution_contract.rb" => [ 235, 14, 20 ]
    }
    SOURCES.each do |name, path|
      lines, callables, decisions = expected_caps.fetch(name)
      assert_operator File.readlines(path).length, :<=, lines
      assert_operator metrics.fetch(name).fetch(:callables), :<=, callables
      assert_operator metrics.fetch(name).fetch(:decisions), :<=, decisions
      assert_empty metrics.fetch(name).fetch(:closure_nodes)
    end
    assert_operator SOURCES.values.sum { |path| File.readlines(path).length }, :<=, 635
    assert_operator metrics.values.sum { |item| item.fetch(:callables) }, :<=, 36
    assert_operator metrics.values.sum { |item| item.fetch(:decisions) }, :<=, 48
    values_path = File.join(ROOT, "packaging/live_agent_skills/workflow_creator_values.rb")
    safety_path = File.join(ROOT, "packaging/live_agent_skills/workflow_creator_text_safety.rb")
    values = static_metrics(File.read(values_path))
    safety = static_metrics(File.read(safety_path))
    composed_sources = SOURCES.values + [ values_path, safety_path ]
    assert_operator composed_sources.sum { |path| File.readlines(path).length }, :<=, 1_135
    assert_operator metrics.values.sum { |item| item.fetch(:callables) } + values.fetch(:callables) +
                    safety.fetch(:callables), :<=, 70
    assert_operator metrics.values.sum { |item| item.fetch(:decisions) } + values.fetch(:decisions) +
                    safety.fetch(:decisions), :<=, 104
    assert_r43_rubocop
  end

  private

  def assert_snapshot(snapshot)
    assert_equal "#<HiveLiveAgentProof::WorkflowCreator::Values snapshot>", snapshot.inspect
    assert snapshot.frozen?
    assert_deeply_frozen(snapshot.value)
    assert snapshot.canonical_bytes.frozen?
  end

  def assert_deeply_frozen(value)
    assert value.frozen?
    case value
    when Hash
      value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) }
    when Array
      value.each { |nested| assert_deeply_frozen(nested) }
    end
  end

  def validate_primary(fixture)
    Creator.validate_primary!(row: fixture.fetch(:row), manifest: fixture.fetch(:manifest), candidate_sha: SHA,
                              bundle_records: fixture.fetch(:bundle_records))
  end

  def validate_execution(fixture)
    Creator.validate_execution!(
      receipt: fixture.fetch(:receipt), row: fixture.fetch(:row), candidate_sha: SHA,
      manifest: fixture.fetch(:manifest),
      installation_records: fixture.fetch(:installation_records) { fixture.fetch(:bundle_records).first(2) },
      receipt_sha256: fixture.fetch(:receipt_sha256),
      candidate_installation: fixture.fetch(:installations).fetch("candidate"),
      openclaw_installation: fixture.fetch(:installations).fetch("openclaw")
    )
  end

  def valid_fixture
    manifest = artifact_manifest
    installations = %w[candidate openclaw].to_h { |kind| [ kind, installation(kind, manifest) ] }
    records = installation_records(installations)
    row = primary_row(manifest, records)
    receipt = execution_receipt(row, records, installations)
    bind_receipt!(row, records, receipt)
    { manifest:, installations:, bundle_records: records, row:, receipt:,
      receipt_sha256: records.fetch(2).fetch("sha256") }
  end

  def artifact_manifest
    version = "1.2.3"
    names = [ "hive-agent-skills-#{SHA}.tar.gz", "hive-cli-#{version}.gem", "hive-source-#{SHA}.tar.gz" ]
    {
      "schema" => "hive-live-agent-candidate-artifacts", "schema_version" => 1, "candidate_sha" => SHA,
      "hive_version" => version, "skill_version" => "2026.8.4",
      "canonical_digest" => Digest::SHA256.hexdigest("canonical"),
      "files" => names.sort.to_h do |name|
        [ name, { "sha256" => Digest::SHA256.hexdigest(name), "size" => name.bytesize } ]
      end
    }
  end

  def installation(kind, manifest)
    roles = Creator::Vocabulary.fetch("member_roles").fetch(kind).to_h do |role|
      path = role == "package" ? "packages/#{kind}.pkg" : "#{role}/fixture"
      artifact = manifest.fetch("files").fetch("hive-cli-1.2.3.gem") if kind == "candidate" && role == "package"
      [ role, { "path" => path, "sha256" => artifact&.fetch("sha256") || Digest::SHA256.hexdigest(path),
                "size" => artifact&.fetch("size") || path.bytesize } ]
    end
    dependency = { "path" => "runtime/dependency.rb", "sha256" => Digest::SHA256.hexdigest("dependency"), "size" => 21 }
    inventory = [ *roles.values.map { |record| deep_dup(record) }, dependency ].sort_by { |record| record.fetch("path") }
    closure = { "required_roles" => roles, "inventory" => inventory }
    {
      "schema" => Creator::Vocabulary.fetch("installed_schema"), "schema_version" => 1,
      "candidate_sha" => SHA, "kind" => kind,
      "version" => kind == "candidate" ? manifest.fetch("hive_version") : "fixture-openclaw",
      "closure_sha256" => Digest::SHA256.hexdigest(canonical(closure)), "required_roles" => roles,
      "inventory" => inventory, "total_size" => inventory.sum { |record| record.fetch("size") },
      "secret_scan" => passing_scan
    }
  end

  def installation_records(installations)
    %w[candidate openclaw].each_with_index.map do |kind, index|
      bytes = canonical(installations.fetch(kind))
      { "kind" => "#{kind}_installation", "path" => Creator::Vocabulary.fetch("bundle_files").fetch(index + 1),
        "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
    end << { "kind" => "execution_receipt", "path" => "execution-receipt.json",
             "sha256" => Digest::SHA256.hexdigest("pending"), "size" => 1 }
  end

  def primary_row(manifest, records)
    created = Creator::Vocabulary.fetch("files").map do |path|
      { "path" => path, "sha256" => Digest::SHA256.hexdigest(path), "size" => path.bytesize }
    end
    summary = { "status" => "passed", "receipt_sha256" => records.fetch(2).fetch("sha256") }
    {
      "schema" => Creator::Vocabulary.fetch("evidence_schema"), "schema_version" => 1, "platform" => "openclaw",
      "candidate_sha" => SHA, "result" => "passed",
      "prompt_sha256" => Digest::SHA256.hexdigest(Creator::Vocabulary.fetch("prompt")),
      "task_prompt_sha256" => Digest::SHA256.hexdigest(Creator::Vocabulary.fetch("task_prompt")),
      "skill" => { "skill_version" => manifest.fetch("skill_version"),
                   "canonical_digest" => manifest.fetch("canonical_digest") },
      "native_activation" => deep_dup(Creator::Vocabulary.fetch("native_activation")),
      "hive_commands" => deep_dup(Creator.commands_for(task_slug: TASK_SLUG).value), "created_files" => created,
      "validation" => deep_dup(Creator::Vocabulary.fetch("graph")), "creation_only_task_count" => 0,
      "task_count" => 1, "task" => deep_dup(Creator::Vocabulary.fetch("task")).merge("slug" => TASK_SLUG),
      "external_actions" => [],
      "secret_scan" => passing_scan, "execution_kind" => "authenticated_openclaw", "model_loop" => "executed",
      "executed_instruction" => deep_dup(created.fetch(2)), "evidence_bundle" => deep_dup(records),
      "containment" => deep_dup(summary), "teardown" => deep_dup(summary), "cleanup" => deep_dup(summary)
    }
  end

  def execution_receipt(row, records, installations)
    command_labels = Creator::Vocabulary.fetch("command_labels")
    commands = Creator.commands_for(task_slug: TASK_SLUG).value.each_with_index.map do |argv, index|
      process_receipt("attempt_label" => command_labels.fetch(index)).merge(
        "position" => index + 1, "argv" => deep_dup(argv)
      )
    end
    outer = Creator::Vocabulary.fetch("outer_roles").each_with_index.map do |identity, index|
      process_receipt("label" => %w[outer-workflow-creator outer-authorized-work].fetch(index)).merge(
        deep_dup(identity), "argv_sha256" => Digest::SHA256.hexdigest("outer-#{index}")
      )
    end
    labels = command_labels + outer.map { |process| process.fetch("label") }
    correlation = "workflow-creator-proof-run"
    packages = installations.values.map { |document| document.dig("required_roles", "package") }
    archives = packages.each_with_index.map do |package, index|
      { "label" => Creator::Vocabulary.fetch("archive_labels").fetch(index),
        "artifact_sha256" => package.fetch("sha256"), "artifact_size" => package.fetch("size"),
        "policy_sha256" => Creator::Vocabulary.fetch("archive_policy_sha256"),
        "entry_count" => 5, "uncompressed_bytes" => 1_024, "status" => "passed" }
    end
    instruction = deep_dup(row.fetch("executed_instruction"))
    {
      "schema" => Creator::Vocabulary.fetch("execution_schema"), "schema_version" => 1,
      "candidate_sha" => SHA, "result" => "passed", "execution_plan" => Creator::Vocabulary.fetch("execution_plan"),
      "classification" => { "outer" => deep_dup(Creator::Vocabulary.fetch("classification")),
                            "nested_stage" => { "execution_kind" => "deterministic_fixture",
                                                "model_loop" => "not_exercised" } },
      "installed_manifests" => deep_dup(records.first(2)),
      "task_slug_binding" => deep_dup(Creator::Vocabulary.fetch("task_slug_binding")).merge("value" => TASK_SLUG),
      "run" => { "correlation_id" => correlation, "expected_labels" => labels },
      "gateway" => { "identity" => deep_dup(installations.fetch("candidate").dig("required_roles", "audit_gateway")),
                     "command_labels" => command_labels, "status" => "passed" },
      "archive_admissions" => archives, "commands" => commands, "outer_processes" => outer,
      "authored_instruction" => deep_dup(instruction), "executed_instruction" => instruction,
      "external_actions" => [],
      "containment" => { "status" => "passed", "mechanism" => "supervised-process-tree",
                         "established_before_launch" => true, "owner_correlation_id" => correlation,
                         "root_loss_behavior" => "fail-closed" },
      "teardown" => { "status" => "passed", "expected_labels" => labels, "receipt_labels" => deep_dup(labels),
                      "outer_root_reaped" => true, "remaining_descendants" => 0 },
      "cleanup" => { "status" => "passed", "targets" => [
        { "label" => "proof-workspace", "path_sha256" => Digest::SHA256.hexdigest("workspace"),
          "device" => 1, "inode" => 2, "created_by_run" => true, "identity_matched" => true, "removed" => true }
      ] }, "secret_scan" => passing_scan
    }
  end

  def process_receipt(label)
    label.merge(
      "exit_code" => 0, "signal" => nil, "completed" => true,
      "capture" => { "limit_bytes" => 4_096, "stdout_bytes" => 0, "stderr_bytes" => 0,
                     "stdout_sha256" => Digest::SHA256.hexdigest(""),
                     "stderr_sha256" => Digest::SHA256.hexdigest(""),
                     "stdout_truncated" => false, "stderr_truncated" => false, "secret_scan" => passing_scan },
      "teardown" => { "status" => "passed", "term_sent" => false, "kill_sent" => false,
                      "reaped" => true, "descendants" => "none", "owner_complete" => true }
    )
  end

  def bind_receipt!(row, records, receipt)
    bytes = canonical(receipt)
    record = records.fetch(2)
    record["sha256"], record["size"] = Digest::SHA256.hexdigest(bytes), bytes.bytesize
    row.fetch("evidence_bundle")[2] = deep_dup(record)
    summary = { "status" => "passed", "receipt_sha256" => record.fetch("sha256") }
    %w[containment teardown cleanup].each { |field| row[field] = deep_dup(summary) }
  end

  def canonical(value) = Values.capture(value).canonical_bytes
  def passing_scan = { "status" => "passed", "scanner" => Creator::Vocabulary.fetch("scanner") }
  def deep_dup(value) = Marshal.load(Marshal.dump(value))

  def poison(value, *names)
    names.each { |name| value.define_singleton_method(name) { |*| raise "caller dispatch: #{name}" } }
  end

  def static_metrics(source)
    syntax = Ripper.sexp(source) or raise "invalid Ruby source"
    metrics = { callables: 0, decisions: 0, closure_nodes: [] }
    walk = lambda do |node|
      next unless node.instance_of?(Array)
      type = node.first
      metrics[:callables] += 1 if %i[def defs].include?(type)
      if type == :lambda || proc_block_kind(node)
        metrics[:callables] += 1
        metrics[:closure_nodes] << type
      end
      metrics[:decisions] += 1 if DECISIONS.include?(type)
      metrics[:decisions] += 1 if type == :binary && %i[&& ||].include?(node[2])
      node.each { |child| walk.call(child) }
    end
    walk.call(syntax)
    metrics
  end

  def proc_block_kind(node)
    return unless node.first == :method_add_block
    call = node[1]
    identifiers = []
    constants = []
    collect = lambda do |child|
      next unless child.instance_of?(Array)
      identifiers << child[1] if child.first == :@ident
      constants << child[1] if child.first == :@const
      child.each { |nested| collect.call(nested) }
    end
    collect.call(call)
    return :proc_new if constants.include?("Proc") && identifiers.include?("new")
    :proc if identifiers.include?("lambda") || identifiers.include?("proc")
  end

  def assert_r43_rubocop
    overlay = {
      "AllCops" => { "TargetRubyVersion" => 3.4, "DisabledByDefault" => true, "NewCops" => "disable" },
      "Metrics/CyclomaticComplexity" => { "Enabled" => true, "Max" => 15 },
      "Metrics/PerceivedComplexity" => { "Enabled" => true, "Max" => 15 },
      "Metrics/AbcSize" => { "Enabled" => true, "Max" => 25 },
      "Metrics/MethodLength" => { "Enabled" => true, "Max" => 40 },
      "Layout/LineLength" => { "Enabled" => true, "Max" => 120 }
    }
    Dir.mktmpdir do |directory|
      config = File.join(directory, "u1a1c-rubocop.yml")
      File.write(config, YAML.dump(overlay))
      rubocop = File.join(Bundler.load.specs.find { |spec| spec.name == "rubocop" }.full_gem_path, "exe", "rubocop")
      out, status = Open3.capture2e(RbConfig.ruby, rubocop, "--config", config, "--format", "simple", *SOURCES.values,
                                    chdir: ROOT)
      assert status.success?, out
    end
  end
end
