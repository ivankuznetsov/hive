require "test_helper"
require "hive/task_capabilities/store"

class TaskCapabilitiesStoreTest < Minitest::Test
  include HiveTestHelper

  def with_task
    with_tmp_dir do |dir|
      prepare_test_runtime_project(dir)
      folder = File.join(dir, ".hive-state/stages/1-inbox/capability-task")
      Hive::TaskMeta.write(folder, id: 42, slug: "capability-task", display_name: nil)
      catalog = Hive::TaskCapabilities::Catalog.new(workflow: Hive::Workflows::Coding::DESCRIPTOR)
      plan = Hive::TaskCapabilities::Plan.minimal(task_identity: Hive::TaskMeta.stable_identity(Hive::TaskMeta.read(folder)), catalog: catalog, source: { "workflow" => "coding" }, policy: {})
      Hive::TaskMeta.rewrite(folder, task_capabilities: plan.adoption)
      yield folder, plan, Hive::TaskCapabilities::Store.new(folder)
    end
  end

  def test_legacy_reads_do_not_write_or_infer
    with_tmp_dir do |dir|
      store = Hive::TaskCapabilities::Store.new(dir)
      assert_nil store.current
      assert_empty store.history
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.read_plan("a" * 64) }
      assert_empty Dir.children(dir)
    end
  end

  def test_missing_or_replaced_task_root_cannot_downgrade_to_legacy
    with_tmp_dir do |dir|
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { Hive::TaskCapabilities::Store.new(File.join(dir, "missing")).current }
      target = File.join(dir, "regular-file")
      File.write(target, "not a task directory")
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { Hive::TaskCapabilities::Store.new(target).current }
      link = File.join(dir, "task-symlink")
      File.symlink(dir, link)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { Hive::TaskCapabilities::Store.new(link).current }
    end
  end

  def test_initial_plan_and_revision_are_immutable_and_history_is_retained
    with_task do |folder, plan, store|
      assert_equal plan.digest, store.activate(plan, expected_version: nil).digest
      assert_equal plan.digest, store.current.digest
      assert_equal 1, store.current.version
      assert_equal({ "qa" => "automatic", "ui" => "automatic", "security" => "automatic" }, plan.data.fetch("inputs"))
      revised = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2))
      store.activate(revised, expected_version: 1)
      assert_equal 2, store.current.version
      assert_equal [ plan.digest, revised.digest ], store.history.map(&:digest)
      assert_equal plan.adoption, Hive::TaskMeta.read_for_admission(folder).data.fetch(:task_capabilities)
      assert_raises(Hive::TaskCapabilities::Store::Conflict) { store.activate(revised, expected_version: 1) }
    end
  end

  def test_unchained_blobs_and_tampering_never_become_authoritative
    with_task do |folder, plan, store|
      store.activate(plan, expected_version: nil)
      fake = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2))
      File.write(File.join(folder, "execution-plans", "#{fake.digest}.json"), fake.bytes)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.read_plan(fake.digest) }
      File.write(File.join(folder, "execution-plans", "#{plan.digest}.json"), fake.bytes)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
    end
  end

  def test_read_time_redaction_changes_cannot_rewrite_accepted_identity
    with_task do |folder, plan, store|
      initial = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("waivers" => [ { "reason" => "historical-safe" } ]))
      Hive::TaskMeta.rewrite(folder, task_capabilities: initial.adoption)
      store.activate(initial, expected_version: nil)
      redactor = Hive::SecretPatterns.method(:redact)
      with_replaced_singleton_method(Hive::SecretPatterns, :redact, ->(text) { redactor.call(text).gsub("historical-safe", "redacted-now") }) do
        assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
        assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.read_plan(initial.digest) }
      end
      seen = 0
      with_replaced_singleton_method(Hive::SecretPatterns, :redact, lambda { |text|
        seen += 1 if text == "historical-safe"
        value = redactor.call(text)
        seen > 1 ? value.gsub("historical-safe", "redacted-now") : value
      }) do
        assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.read_plan(initial.digest) }
      end
    end
  end

  def test_corrupt_adoption_missing_pointer_and_unaccepted_results_fail_closed
    with_task do |folder, plan, store|
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
      store.activate(plan, expected_version: nil)
      File.write(File.join(folder, "execution-plan-current.json"), "{}")
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
    end
  end

  def test_controller_accepts_results_and_approvals_with_identity_and_digest_checks
    with_task do |folder, plan, store|
      store.activate(plan, expected_version: nil)
      data = { "task" => plan.to_h.fetch("task"), "execution_plan_digest" => plan.digest, "reason" => "key ghp_#{'a' * 36}" }
      forged = { "task" => plan.to_h.fetch("task"), "execution_plan_digest" => plan.digest, "state" => "passed", "check_id" => "qa" }
      forged_bytes = Hive::WorkflowPackage::CanonicalJSON.generate(forged)
      forged_digest = Digest::SHA256.hexdigest(forged_bytes)
      FileUtils.mkdir_p(File.join(folder, "capability-results"))
      File.write(File.join(folder, "capability-results", "#{forged_digest}.json"), forged_bytes)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.read_blob("result", forged_digest) }
      assert_equal plan.digest, store.current.digest
      digest = store.accept_blob("result", data)
      assert_includes store.read_blob("result", digest).fetch("reason"), "[REDACTED:github_token]"
      approval = store.accept_blob("approval", data)
      assert_equal plan.digest, store.read_blob("approval", approval).fetch("execution_plan_digest")
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.accept_blob("result", data.merge("task" => {})) }
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.read_blob("result", "../escape") }
      File.write(File.join(folder, "capability-results", "#{digest}.json"), "{}")
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
    end
  end

  def test_initial_approval_has_no_execution_plan_digest_cycle
    with_task do |folder, plan, store|
      data = { "task" => plan.to_h.fetch("task"), "envelope" => { "targets" => [ "fixtures/local" ] } }
      digest = Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(data))
      initial = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("approvals" => [ { "digest" => digest } ]))
      Hive::TaskMeta.rewrite(folder, task_capabilities: initial.adoption)
      assert_equal initial.digest, store.activate(initial, expected_version: nil, approvals: [ data ]).digest
      assert_equal data, store.read_blob("approval", digest)
      assert_equal initial.digest, store.current.digest
      File.unlink(File.join(folder, "capability-approvals", "#{digest}.json"))
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
    end
  end

  def test_unaccepted_approval_cannot_be_published
    with_task do |folder, plan, store|
      initial = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("approvals" => [ "a" * 64 ]))
      Hive::TaskMeta.rewrite(folder, task_capabilities: initial.adoption)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.activate(initial, expected_version: nil) }
      refute File.exist?(File.join(folder, "execution-plan-current.json"))
    end
  end

  def test_capability_anchor_custody_restores_agent_mutation_and_ignores_plan_document
    require "hive/stages/base"
    with_task do |folder, plan, store|
      store.activate(plan, expected_version: nil)
      task = Struct.new(:folder).new(folder)
      pointer = File.binread(File.join(folder, "execution-plan-current.json"))
      custody = Hive::Stages::Base.capability_anchor_custody(task)
      assert_raises(Hive::StageError) do
        custody.call { File.write(File.join(folder, "execution-plan-current.json"), "{}") }
      end
      assert_equal pointer, File.binread(File.join(folder, "execution-plan-current.json"))
      metadata = File.binread(File.join(folder, "meta.yml"))
      assert_raises(Hive::StageError) do
        Hive::Stages::Base.capability_anchor_custody(task).call do
          value = YAML.safe_load(metadata)
          value.delete("task_capabilities")
          File.write(File.join(folder, "meta.yml"), value.to_yaml)
        end
      end
      assert_equal metadata, File.binread(File.join(folder, "meta.yml"))
      assert_equal plan.digest, store.current.digest
      assert_equal :ok, Hive::Stages::Base.capability_anchor_custody(task).call {
        File.write(File.join(folder, "plan.md"), "agent's stage document")
        :ok
      }
    end
  end

  def test_rejects_invalid_metadata_and_attempts_to_remove_adoption
    with_task do |folder, plan, store|
      store.activate(plan, expected_version: nil)
      File.write(File.join(folder, "meta.yml"), "task_capabilities: false\n")
      assert_raises(Hive::TaskMeta::InvalidMetadata) { Hive::TaskMeta.read(folder) }
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
      refute Hive::TaskMeta.read_for_admission(folder).ok?
      File.write(File.join(folder, "meta.yml"), "id: 42\nslug: capability-task\n")
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
    end
  end

  def test_metadata_rejects_partial_unknown_duplicate_and_malformed_adoption
    with_task do |folder, plan, _store|
      original = Hive::TaskMeta.snapshot(folder)
      [ {}, false, plan.adoption.merge("adopted" => false), plan.adoption.merge("extra" => true),
        plan.adoption.merge("initial_plan_digest" => "wrong"), plan.adoption.merge("initial_plan_version" => 2),
        plan.adoption.merge(1 => "wrong") ].each do |value|
        data = YAML.safe_load(original.bytes)
        data["task_capabilities"] = value
        File.write(File.join(folder, "meta.yml"), data.to_yaml)
        refute Hive::TaskMeta.read_for_admission(folder).ok?
      end
      File.write(File.join(folder, "meta.yml"), original.bytes + "task_capabilities: false\n")
      refute Hive::TaskMeta.read_for_admission(folder).ok?
    end
  end

  def append_raw_acceptance(folder, kind, data)
    bytes = Hive::WorkflowPackage::CanonicalJSON.generate(data)
    digest = Digest::SHA256.hexdigest(bytes)
    directory = File.join(folder, Hive::TaskCapabilities::Store::DIRECTORIES.fetch(kind))
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "#{digest}.json"), bytes)
    path = File.join(folder, "capability-accepted.jsonl")
    lines = File.readlines(path)
    identity = Hive::WorkflowPackage::CanonicalJSON.normalize(Hive::TaskMeta.stable_identity(Hive::TaskMeta.read(folder)))
    lines << Hive::WorkflowPackage::CanonicalJSON.generate("sequence" => lines.length + 1,
      "previous" => lines.last && Digest::SHA256.hexdigest(lines.last), "kind" => kind, "digest" => digest, "task" => identity)
    File.write(path, lines.join)
    digest
  end

  def test_acceptance_chain_rejects_invalid_identity_and_dangling_references
    with_task do |folder, plan, store|
      wrong = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("task" => plan.to_h.fetch("task").merge("id" => "other")))
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.activate(wrong, expected_version: nil) }
      store.activate(plan, expected_version: nil)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.accept_blob("unknown", {}) }
      chain = File.binread(File.join(folder, "capability-accepted.jsonl"))
      [ [ "plan", wrong.to_h ],
        [ "result", { "task" => plan.to_h.fetch("task"), "execution_plan_digest" => "a" * 64 } ],
        [ "plan", plan.to_h.merge("version" => 2, "approvals" => [ "a" * 64 ]) ] ].each do |kind, data|
        append_raw_acceptance(folder, kind, data)
        assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
        File.write(File.join(folder, "capability-accepted.jsonl"), chain)
      end
      File.write(File.join(folder, "capability-accepted.jsonl"), "")
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
      File.write(File.join(folder, "capability-accepted.jsonl"), chain.sub('"sequence":1', '"sequence":99'))
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
    end
  end

  def test_pointer_and_store_paths_reject_symlinks_invalid_json_and_version_mismatch
    with_task do |folder, plan, store|
      store.activate(plan, expected_version: nil)
      pointer = File.join(folder, "execution-plan-current.json")
      bytes = File.binread(pointer)
      File.write(pointer, JSON.generate(JSON.parse(bytes).merge("version" => 99)))
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
      File.write(pointer, "not JSON")
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
      File.write(pointer, bytes)
      File.rename(pointer, "#{pointer}-original")
      File.symlink("#{pointer}-original", pointer)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
      File.unlink(pointer)
      File.rename("#{pointer}-original", pointer)
      directory = File.join(folder, "execution-plans")
      File.rename(directory, "#{directory}-original")
      File.symlink("#{directory}-original", directory)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
      File.unlink(directory)
      File.rename("#{directory}-original", directory)
      results = File.join(folder, "capability-results")
      File.symlink(directory, results)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) do
        store.accept_blob("result", { "task" => plan.to_h.fetch("task"), "execution_plan_digest" => plan.digest })
      end
      chain = File.join(folder, "capability-accepted.jsonl")
      File.rename(chain, "#{chain}-original")
      File.symlink("#{chain}-original", chain)
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.current }
    end
  end

  def test_controller_can_accept_a_valid_declared_proposal_blob_but_not_directory_authority
    with_task do |folder, plan, store|
      FileUtils.mkdir_p(File.join(folder, "execution-plans"))
      File.write(File.join(folder, "execution-plans", "#{plan.digest}.json"), plan.bytes)
      store.activate(plan, expected_version: nil)
      assert_equal plan.digest, store.current.digest
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.send(:load_blob, "plan", "../outside") }
    end
  end

  def test_observation_rejects_a_same_path_replacement
    with_task do |folder, plan, store|
      observation = Hive::TaskMeta.observe(folder)
      File.rename(folder, "#{folder}-old")
      FileUtils.cp_r("#{folder}-old", folder)
      assert_raises(Hive::TaskMeta::StaleTask) { store.activate(plan, expected_version: nil, observation: observation) }
    ensure
      observation&.close
    end
  end

  def test_crash_before_pointer_activation_retains_previous_plan
    with_task do |folder, plan, store|
      store.activate(plan, expected_version: nil)
      revised = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2))
      original = Hive::AtomicFile.method(:write)
      with_replaced_singleton_method(Hive::AtomicFile, :write, lambda { |path, *args, **kwargs|
        raise "simulated crash" if File.basename(path) == "execution-plan-current.json"
        original.call(path, *args, **kwargs)
      }) do
        assert_raises(RuntimeError) { store.activate(revised, expected_version: 1) }
      end
      assert_equal plan.digest, store.current.digest
      assert_equal 2, store.history.length
      store.activate(revised, expected_version: 1)
      assert_equal revised.digest, store.current.digest
    end
  end
end
