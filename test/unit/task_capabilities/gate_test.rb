require "hive/commands/run"
require "hive/task_action"
require "hive/rebase"
require "test_helper"
require_relative "../../support/task_capabilities_fixture"
require "hive/task_capabilities/gate"

class TaskCapabilitiesGateTest < Minitest::Test
  include HiveTestHelper
  include TaskCapabilitiesFixture

  def test_adopted_task_requires_current_accepted_behavior_proof
    with_verification do |verification, _plan, _store, code, cfg, task|
      gate = Hive::TaskCapabilities::Gate.new(task: task, cfg: cfg, worktree_path: code)
      refute gate.evaluate.fetch("allowed")
      assert_raises(Hive::TaskCapabilities::Gate::Blocked) { gate.enforce! }
      verification.run!
      assert gate.evaluate.fetch("allowed"), gate.evaluate.inspect
      File.write(File.join(code, "README.md"), "changed bytes")
      refute gate.evaluate.fetch("allowed")
    end
  end

  def git(code, *args)
    out, err, status = Open3.capture3("git", "-C", code, *args)
    assert status.success?, err
    out.strip
  end

  def commit(code, message)
    git(code, "add", ".")
    git(code, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", message)
  end

  def gate(task, cfg, code)
    Hive::TaskCapabilities::Gate.new(task: task, cfg: cfg, worktree_path: code)
  end

  def test_exact_sha_change_is_stale_but_complete_patch_identical_rewrite_is_proven_and_recorded
    with_verification do |verification, plan, store, code, cfg, task|
      git(code, "branch", "-M", "main")
      git(code, "update-ref", "refs/remotes/origin/main", "main")
      git(code, "checkout", "-qb", "task")
      File.write(File.join(code, "README.md"), "task change\n")
      commit(code, "first implementation")
      old = git(code, "rev-parse", "HEAD")
      verification.run!
      delta = Hive::TaskCapabilities::Result.task_delta(code, sha: old)
      refute_nil delta
      refute_empty delta.fetch("patch_ids")
      git(code, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--amend", "-qm", "rewritten message")
      rewritten = git(code, "rev-parse", "HEAD")
      refute_equal old, rewritten
      value = gate(task, cfg, code).enforce!
      assert value.fetch("allowed"), Hive::TaskCapabilities::Gate.summary(value).inspect
      assert_equal old, value.dig("checks", 0, "equivalence", "old_sha")
      assert_equal rewritten, value.dig("checks", 0, "equivalence", "new_sha")
      receipt = store.blobs("result").find { |_digest, data| data["record_type"] == "equivalence" }
      assert receipt
      assert_equal old, receipt.last.dig("proof", "old_sha")
      File.write(File.join(code, "README.md"), "real code change\n")
      commit(code, "changed implementation")
      refute gate(task, cfg, code).evaluate.fetch("allowed")
      assert_equal "passed", verification.run!.fetch("state")
      assert gate(task, cfg, code).evaluate.fetch("allowed")
    end
  end

  def test_relevant_base_change_and_ambiguous_empty_commit_cannot_reuse_evidence
    with_verification do |verification, _plan, _store, code, cfg, task|
      git(code, "branch", "-M", "main")
      git(code, "update-ref", "refs/remotes/origin/main", "main")
      git(code, "checkout", "-qb", "task")
      File.write(File.join(code, "README.md"), "task change\n")
      commit(code, "implementation")
      verification.run!
      git(code, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-qm", "empty")
      refute gate(task, cfg, code).evaluate.fetch("allowed")
      refute Hive::TaskCapabilities::Result.equivalent_delta?(nil, {})
      refute Hive::TaskCapabilities::Result.equivalent_delta?({}, {})
    end
  end

  def test_unavailable_security_is_a_dynamic_blocker_and_restoring_exact_route_recovers
    security = actor_definition(id: "security")
    security.fetch("actor")["launch_binding"] = "default"
    security["permissions"] = { "tools" => [ "Read" ], "commands" => [], "domains" => [] }
    approval = security.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => "security")
    configure = ->(cfg, _dir) { cfg["task_capabilities"]["approvals"] = { "approved" => approval } }
    with_verification(catalog: [ security ], selections: [ "security=on" ], approval_references: [ "security=approved" ], configure: configure) do |verification, _plan, _store, code, cfg, task|
      result = with_actor_response { verification.run! }
      assert_equal "passed", result.fetch("state"), result.inspect
      assert gate(task, cfg, code).evaluate.fetch("allowed")
      saved = cfg.fetch("agents").fetch("claude").fetch("bin")
      cfg["agents"]["claude"]["bin"] = "/missing/approved-runtime"
      blocked = gate(task, cfg, code).evaluate
      refute blocked.fetch("allowed")
      assert_equal "blocked", blocked.fetch("capabilities").find { |item| item["id"] == "security" }.fetch("state")
      assert_equal "passed", blocked.fetch("checks").find { |item| item["capability_id"] == "qa" }.fetch("state")
      cfg["agents"]["claude"]["bin"] = saved
      assert gate(task, cfg, code).evaluate.fetch("allowed")
      account = Hive::ProviderRouting::Account.new(id: "new-default", adapter: "claude", launch_binding: "default", models: [ "approved" ], max_concurrent: 2, cooldown_sec: {})
      cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] = { account.id => account }
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
  end

  def test_qa_waiver_is_distinct_and_hard_required_or_security_waivers_fail_closed
    with_verification(selections: [ "qa=off" ], qa_waiver_reason: "Human executes behavior checks", qa_waiver_checks: [ "all" ]) do |_verification, plan, store, code, cfg, task|
      value = gate(task, cfg, code).evaluate
      assert value.fetch("allowed"), Hive::TaskCapabilities::Gate.summary(value).inspect
      assert_equal "waived", value.fetch("state")
      invalid = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2, "policy" => { "policy" => { "required" => [ "qa" ] } }))
      store.activate(invalid, expected_version: 1)
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
  end

  def test_missing_corrupt_unaccepted_results_and_replaced_or_disappeared_task_never_downgrade
    with_verification do |verification, _plan, _store, code, cfg, task|
      verification.run!
      pointer = File.join(task.folder, Hive::TaskCapabilities::Store::POINTER)
      original = File.binread(pointer)
      File.delete(pointer)
      refute gate(task, cfg, code).evaluate.fetch("allowed")
      File.write(pointer, original)
      blob = Dir[File.join(task.folder, "capability-results/*.json")].last
      File.write(blob, "{}")
      refute gate(task, cfg, code).evaluate.fetch("allowed")
      FileUtils.rm_rf(task.folder)
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
    with_verification do |_verification, _plan, _store, code, cfg, task|
      Hive::TaskMeta.rewrite(task.folder, id: task.id + 100)
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
  end

  def test_external_closure_records_neither_pass_nor_waive_checks_and_retains_reference
    with_verification(command: "ruby -e 'exit 1'") do |verification, plan, _store, code, cfg, task|
      verification.run!
      results = Hive::TaskCapabilities::ResultStore.new(task.folder)
      before = results.history.map(&:first)
      digest = results.record_terminal!(disposition: "closed-out-of-band", reference: "closure:#{'a' * 64}")
      assert_equal before, results.history.map(&:first)
      assert_equal digest, results.terminal_history.last.first
      assert_equal "Closed out-of-band — gate not evaluated", results.terminal_history.last.last.fetch("label")
      value = gate(task, cfg, code).evaluate
      refute value.fetch("allowed")
      assert_equal "failed", value.fetch("state")
      assert_equal plan.digest, value.fetch("execution_plan_digest")
      assert_equal "closed-out-of-band", Hive::TaskCapabilities::Gate.summary(value).fetch("terminal_dispositions").first.fetch("disposition")
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.record_terminal!(disposition: "waived", reference: "operator") }
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.record_terminal!(disposition: "cancelled", reference: "") }
    end
  end

  def test_force_independent_transition_boundary_permits_review_and_backward_recovery_only
    with_verification do |_verification, _plan, _store, code, cfg, task|
      assert Hive::TaskCapabilities::Gate.transition!(task: task, destination: "6-review", cfg: cfg)
      assert Hive::TaskCapabilities::Gate.transition!(task: task, destination: "4-execute", cfg: cfg)
      %w[7-artifacts 8-finalize 9-done].each do |dest|
        assert_raises(Hive::TaskCapabilities::Gate::Blocked) { Hive::TaskCapabilities::Gate.transition!(task: task, destination: dest, cfg: cfg) }
      end
    end
  end

  def test_initially_absent_approved_account_recovers_only_the_exact_pinned_actor_tuple
    security = actor_definition(id: "security")
    security.fetch("actor").merge!("provider_account" => "approved-account", "launch_binding" => "default")
    security["permissions"] = { "tools" => [ "Read" ], "commands" => [], "domains" => [] }
    approval = security.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => "security")
    configure = ->(cfg, _dir) { cfg["task_capabilities"]["approvals"] = { "approved" => approval } }
    with_verification(catalog: [ security ], selections: [ "security=on" ], approval_references: [ "security=approved" ], configure: configure) do |verification, plan, _store, code, cfg, task|
      assert_equal "blocked", verification.run!.fetch("state")
      account = Hive::ProviderRouting::Account.new(id: "approved-account", adapter: "claude", launch_binding: "default", models: [ "approved" ], max_concurrent: 2, cooldown_sec: {})
      cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] = { account.id => account }
      result = with_actor_response { verification.run! }
      security_result = result.fetch("checks").find { |check| check["capability_id"] == "security" }
      assert_equal "passed", security_result.fetch("state"), security_result.dig("result", "reason")
      assert gate(task, cfg, code).evaluate.fetch("allowed"), Hive::TaskCapabilities::Gate.summary(gate(task, cfg, code).evaluate).inspect
      assert_equal plan.digest, result.fetch("execution_plan_digest")
      cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] = { account.id => account.with(models: [ "different-model" ]) }
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
  end

  def test_gate_journal_replay_is_bounded_revision_scoped_and_keeps_external_terminal_annotation
    with_verification do |verification, _plan, _store, code, cfg, task, context|
      verification.run!
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        current = gate(task, cfg, code).enforce!
        projected = Hive::TaskProjection::Reader.new(task_folder: task.folder, task: task).read
        assert_equal "passed", projected["capability_gate"]["state"]
        refute_includes JSON.generate(projected["capability_gate"]), "command"
        assert_equal current.fetch("evaluated_sha"), projected["capability_gate"]["evaluated_sha"]
        Hive::TaskCapabilities::Gate.record_terminal!(task: task, disposition: "closed-out-of-band", reference: "https://github.com/acme/app/pull/1")
        replay = Hive::TaskProjection::Reader.new(task_folder: task.folder, task: task).read
        assert_equal "Closed out-of-band — gate not evaluated", replay["capability_terminal"]["label"]
        activity = Hive::TaskActivity.for_context(task, context: context, commit_generation: 1)
        activity.record(kind: "commit_observed", operation_id: "later-commit", reason: "implementation changed", source: "local_git", payload: { "head_sha" => "d" * 40 })
        replay = Hive::TaskProjection::Reader.new(task_folder: task.folder, task: task).read
        assert_nil replay["capability_gate"]
        assert replay["capability_terminal"]
      end
    end
  end

  def test_real_pre_stage_rebase_proves_whole_delta_and_guards_its_exact_lease_publication
    with_verification do |verification, _plan, store, code, cfg, task|
      git(code, "config", "user.name", "Test")
      git(code, "config", "user.email", "test@example.test")
      git(code, "branch", "-M", "main")
      remote = File.join(task.project_root, "remote.git")
      system("git", "init", "--bare", "-q", remote, exception: true)
      git(code, "remote", "add", "origin", remote)
      git(code, "push", "-qu", "origin", "main")
      git(code, "checkout", "-qb", "task")
      File.write(File.join(code, "README.md"), "task delta\n")
      commit(code, "implementation")
      git(code, "push", "-qu", "origin", "task")
      verification.run!
      old = git(code, "rev-parse", "HEAD")
      git(code, "checkout", "-q", "main")
      git(code, "commit", "--allow-empty", "-qm", "base metadata update")
      git(code, "push", "-q", "origin", "main")
      git(code, "checkout", "-q", "task")
      task.stage_name = "finalize"
      task.stage_index = 8
      cfg["default_branch"] = "main"
      cfg["rebase"] = { "enabled" => true }
      cfg["agent_git_gate"] = { "allow_local_transport" => true }
      result = Hive::Commands::Run.new(task.folder).send(:perform_rebase, task, cfg)
      assert result.succeeded, result.inspect
      current = git(code, "rev-parse", "HEAD")
      refute_equal old, current
      assert_empty result.post_rebase_warnings
      assert_equal current, git(code, "ls-remote", "origin", "refs/heads/task").split.first
      assert store.blobs("result").any? { |_digest, data| data["record_type"] == "equivalence" }
      # A later real code change is never published by the pre-stage hook.
      File.write(File.join(code, "README.md"), "different behavior\n")
      commit(code, "changed code")
      unpublished = git(code, "rev-parse", "HEAD")
      warnings = []
      Hive::Rebase.publish_rebased_branch!(task, cfg, Hive::Rebase::PublishLease.new(branch: "task", remote_oid: current), warnings)
      refute_empty warnings
      refute_equal unpublished, git(code, "ls-remote", "origin", "refs/heads/task").split.first
    end
  end

  def test_finding_scoped_risk_acceptance_never_waives_unavailable_or_unrun_security
    security = actor_definition(id: "security")
    security.fetch("actor")["launch_binding"] = "default"
    security["permissions"] = { "tools" => [ "Read" ], "commands" => [], "domains" => [] }
    approval = security.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => "security")
    configure = ->(cfg, _dir) { cfg["task_capabilities"]["approvals"] = { "approved" => approval } }
    response = ->(_task, _args, proposal) { JSON.generate(proposal.merge("state" => "failed", "findings" => [ { "id" => "finding-1", "severity" => "low", "summary" => "Existing local risk", "details" => "Requires an operator disposition" } ])) }
    with_verification(catalog: [ security ], selections: [ "security=on" ], approval_references: [ "security=approved" ], configure: configure) do |verification, _plan, store, code, cfg, task, context|
      result = with_actor_response(response) { verification.run! }
      failed = result.fetch("checks").find { |item| item["capability_id"] == "security" }
      results = Hive::TaskCapabilities::ResultStore.new(task.folder)
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        assert_raises(Hive::TaskCapabilities::Admission::Error) { results.record_disposition!(result_digest: failed.fetch("result_digest"), finding_ids: [ "finding-1" ], reference: "operator") }
      end
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.record_disposition!(result_digest: failed.fetch("result_digest"), finding_ids: [ "invented" ], reference: "operator") }
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.record_disposition!(result_digest: failed.fetch("result_digest"), finding_ids: [], reference: "operator") }
      results.record_disposition!(result_digest: failed.fetch("result_digest"), finding_ids: [ "finding-1" ], reference: "operator accepted this specific finding")
      value = gate(task, cfg, code).evaluate
      assert value.fetch("allowed"), Hive::TaskCapabilities::Gate.summary(value).inspect
      assert_equal "waived", value.fetch("state")
      assert_equal "risk-accepted", value.fetch("capabilities").find { |item| item["id"] == "security" }.fetch("disposition")
      assert_equal "failed", store.read_blob("result", failed.fetch("result_digest")).fetch("state")
      cfg["agents"]["claude"]["bin"] = "/missing/approved-runtime"
      refute gate(task, cfg, code).evaluate.fetch("allowed")
      blocked = verification.run!.fetch("checks").find { |item| item["capability_id"] == "security" }
      assert_equal "blocked", blocked.fetch("state")
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.record_disposition!(result_digest: blocked.fetch("result_digest"), finding_ids: [ "finding-1" ], reference: "operator") }
    end
  end

  def test_read_model_does_not_use_viewer_environment_as_execution_authority
    with_verification do |verification, _plan, _store, code, cfg, task|
      verification.run!
      with_env("RAILS_ENV" => "viewer-only", "NODE_ENV" => "viewer", "BUNDLE_GEMFILE" => "/viewer/Gemfile", "BUNDLE_PATH" => "/viewer/bundle", "PATH" => "/usr/bin:/bin") do
        reader = gate(task, cfg, code).read_state
        assert_equal "passed", reader.fetch("state")
        assert_equal "read-model", reader.fetch("authority")
        assert gate(task, cfg, code).evaluate.fetch("allowed")
        assert_equal "passed", gate(task, cfg, code).enforce!.fetch("state")
      end
    end
  end

  def test_invalid_closure_carriers_and_changed_adoption_cannot_authorize_terminal_move
    with_verification do |_verification, _plan, _store, code, cfg, task|
      assert_raises(Hive::TaskCapabilities::Gate::Blocked) do
        Hive::TaskCapabilities::Gate.transition!(task: task, destination: "9-done", cfg: cfg, closure_receipt_digest: "f" * 64)
      end
      cached = Hive::TaskMeta.read(task.folder)
      task.instance_variable_set(:@meta, cached)
      metadata = YAML.safe_load_file(Hive::TaskMeta.path(task.folder))
      metadata.delete("task_capabilities")
      File.write(Hive::TaskMeta.path(task.folder), metadata.to_yaml)
      File.delete(File.join(task.folder, Hive::TaskCapabilities::Store::POINTER))
      File.delete(File.join(task.folder, Hive::TaskCapabilities::Store::CHAIN))
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
  end

  def test_selected_missing_binding_and_changed_actor_bytes_fail_closed
    with_verification do |verification, plan, store, code, cfg, task|
      verification.run!
      changed = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2, "bindings" => []))
      store.activate(changed, expected_version: 1)
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
    configure = lambda do |cfg, dir|
      binary = File.join(dir, "approved-actor")
      FileUtils.cp(cfg.fetch("agents").fetch("claude").fetch("bin"), binary)
      File.chmod(0o755, binary)
      cfg["agents"]["claude"]["bin"] = binary
    end
    with_verification(catalog: [ actor_definition ], selections: [ "audit=on" ], configure: configure) do |verification, _plan, _store, code, cfg, task|
      with_actor_response { verification.run! }
      assert gate(task, cfg, code).evaluate.fetch("allowed")
      path = cfg.fetch("agents").fetch("claude").fetch("bin")
      File.write(path, File.read(path) + "\n# replaced bytes\n")
      refute gate(task, cfg, code).evaluate.fetch("allowed")
      File.write(File.join(code, "README.md"), "new implementation\n")
      commit(code, "new implementation")
      failed = with_actor_response { verification.run! }.fetch("checks").find { |check| check["capability_id"] == "audit" }
      assert_equal "blocked", failed.fetch("state")
      assert_includes failed.dig("result", "reason"), "runtime"
    end
  end

  def test_generic_fourth_gate_and_unchanged_plan_version_reuse
    fourth = { "id" => "fourth", "kind" => "verification", "stages" => [ "review" ], "checks" => [ { "id" => "links", "kind" => "behavior", "claim" => "Verify links", "command" => "ruby -e 'exit 1'" } ] }
    with_verification(catalog: [ fourth ], selections: [ "fourth=on" ]) do |verification, _plan, _store, code, cfg, task|
      verification.run!
      value = gate(task, cfg, code).evaluate
      refute value.fetch("allowed")
      assert_equal "failed", value.fetch("capabilities").find { |item| item["id"] == "fourth" }.fetch("state")
    end
    with_verification do |verification, plan, store, code, cfg, task|
      first = verification.run!.fetch("checks").first.fetch("result_digest")
      revised = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2))
      store.activate(revised, expected_version: 1)
      value = gate(task, cfg, code).evaluate
      assert value.fetch("allowed"), Hive::TaskCapabilities::Gate.summary(value).inspect
      assert_equal first, value.fetch("checks").first.fetch("result_digest")
      assert_equal revised.digest, value.fetch("execution_plan_digest")
    end
  end

  def test_action_read_model_blocks_forward_readiness_without_stopping_review_or_implementation
    with_verification do |verification, _plan, _store, code, cfg, task|
      complete = Hive::Markers::State.new(name: :review_complete, attrs: {}, raw: nil)
      action = Hive::TaskAction.for(task, complete, config: cfg)
      assert_nil action.command
      assert_includes action.label, "Verification required"
      ready = Hive::TaskAction.for(task, Hive::Markers::State.new(name: :none, attrs: {}, raw: nil), config: cfg)
      assert_equal "ready_for_review", ready.key
      verification.run!
      assert_equal "ready_to_artifacts", Hive::TaskAction.for(task, complete, config: cfg).key
      task.stage_name = "execute"
      task.stage_index = 4
      assert_equal "ready_to_open_pr", Hive::TaskAction.for(task, Hive::Markers::State.new(name: :execute_complete, attrs: {}, raw: nil), config: cfg).key
    end
  end

  def test_non_qa_waiver_and_malformed_accepted_variants_cannot_clear_a_gate
    with_verification(selections: [ "qa=off" ], qa_waiver_reason: "Human verification", qa_waiver_checks: [ "all" ]) do |_verification, plan, store, code, cfg, task|
      malformed = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2, "waivers" => [ plan.data.fetch("waivers").first.merge("capability" => "security") ]))
      store.activate(malformed, expected_version: 1)
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
    with_verification do |verification, plan, store, code, cfg, task|
      verification.run!
      results = Hive::TaskCapabilities::ResultStore.new(task.folder)
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.record_equivalence!(plan_digest: "f" * 64, result_digest: "a" * 64, proof: {}) }
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.record_equivalence!(plan_digest: plan.digest, result_digest: "a" * 64, proof: {}) }
      digest, original = results.history.first
      proof = { "old_sha" => original.data.fetch("evaluated_sha"), "new_sha" => "f" * 40,
        "old_delta" => original.data["task_delta"], "new_delta" => original.data["task_delta"] }
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.record_equivalence!(plan_digest: plan.digest, result_digest: digest, proof: proof) }
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { Hive::TaskCapabilities::Result.new(original.to_h.merge("task_delta" => {})) }
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.accept(Hive::TaskCapabilities::Result.new(original.to_h.merge("observed_route" => {}))) }
      assert_nil Hive::TaskCapabilities::Result.task_delta(nil, sha: "a" * 40)
      store.accept_blob("result", { "schema_version" => 1, "task" => plan.data.fetch("task"), "execution_plan_digest" => plan.digest, "record_type" => "invented-success" })
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.history }
      refute gate(task, cfg, code).evaluate.fetch("allowed")
    end
  end

  def test_terminal_overlay_revalidates_after_cached_journal_reads_without_synthetic_attempts
    with_verification do |_verification, _plan, _store, _code, _cfg, task|
      reader = Hive::TaskProjection::Reader.new(task_folder: task.folder, task: task)
      before = reader.read_routine
      assert_nil before.projection["capability_terminal"]
      results = Hive::TaskCapabilities::ResultStore.new(task.folder)
      digest = results.record_terminal!(disposition: "closed-out-of-band", reference: "external PR")
      after = reader.read_routine
      assert_equal before.journal_cursor, after.journal_cursor
      assert_equal digest, after.projection["capability_terminal"]["result_digest"]
      assert_equal digest, reader.read_bounded.projection["capability_terminal"]["result_digest"]
      File.write(File.join(task.folder, "capability-results/#{digest}.json"), "{}")
      assert_equal "invalid", reader.read_routine.projection["capability_terminal"]["state"]
    end
    with_verification do |_verification, _plan, _store, _code, _cfg, task|
      File.delete(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
      task.id += 1
      reader = Hive::TaskProjection::Reader.new(task_folder: task.folder, task: task)
      assert_equal "invalid", reader.read["capability_terminal"]["state"]
    end
  end

  def test_no_rebase_does_not_hide_remote_base_changes_at_an_unchanged_head
    with_verification do |verification, _plan, _store, code, cfg, task|
      git(code, "branch", "-M", "main")
      remote = File.join(task.project_root, "remote.git")
      system("git", "init", "--bare", "-q", remote, exception: true)
      git(code, "remote", "add", "origin", remote)
      git(code, "push", "-qu", "origin", "main")
      git(code, "checkout", "-qb", "task")
      File.write(File.join(code, "README.md"), "task delta\n")
      commit(code, "implementation")
      git(code, "push", "-qu", "origin", "task")
      first = verification.run!.fetch("checks").first
      head = git(code, "rev-parse", "HEAD")
      scratch = File.join(task.project_root, "upstream")
      system("git", "clone", "-q", "--branch", "main", remote, scratch, exception: true)
      File.write(File.join(scratch, "expected.txt"), "changed dependency\n")
      commit(scratch, "changed base")
      git(scratch, "push", "-q", "origin", "main")
      cfg["default_branch"] = "main"
      result = Hive::Commands::Run.new(task.folder, no_rebase: true).send(:perform_rebase, task, cfg)
      assert_equal :cli_override, result.reason
      assert_equal head, git(code, "rev-parse", "HEAD")
      assert_raises(Hive::TaskCapabilities::Gate::Blocked) { gate(task, cfg, code).enforce! }
      assert_equal "stale", gate(task, cfg, code).evaluate.fetch("state")
      rerun = verification.run!.fetch("checks").first
      refute_equal first.fetch("result_digest"), rerun.fetch("result_digest")
      assert_equal head, rerun.fetch("result").fetch("evaluated_sha")
      assert gate(task, cfg, code).enforce!.fetch("allowed")
      git(code, "update-ref", "-d", "refs/remotes/origin/main")
      cfg.delete("default_branch")
      assert_raises(Hive::TaskCapabilities::Gate::Blocked) { gate(task, cfg, code).enforce! }
      cfg["default_branch"] = "main"
      git(code, "remote", "set-url", "origin", File.join(task.project_root, "absent-remote.git"))
      assert_raises(Hive::TaskCapabilities::Gate::Blocked) { gate(task, cfg, code).enforce! }
    end
  end

  def test_retained_task_target_uses_the_exact_branch_ref_and_rejects_invalid_targets
    with_verification do |verification, _plan, _store, code, cfg, task|
      git(code, "branch", "-M", "main")
      remote = File.join(task.project_root, "remote.git")
      system("git", "init", "--bare", "-q", remote, exception: true)
      git(code, "remote", "add", "origin", remote)
      git(code, "push", "-qu", "origin", "main")
      git(code, "checkout", "-qb", "release")
      File.write(File.join(code, "expected.txt"), "release base\n")
      commit(code, "release base")
      git(code, "push", "-qu", "origin", "release")
      git(code, "checkout", "-qb", "task")
      File.write(File.join(code, "README.md"), "task delta\n")
      commit(code, "implementation")
      git(code, "tag", "origin/release")
      cfg["default_branch"] = "main"
      task.define_singleton_method(:base_branch) { "release" }
      check = verification.run!.fetch("checks").first
      assert_equal "refs/remotes/origin/release", check.fetch("result").dig("task_delta", "target_ref")
      assert gate(task, cfg, code).enforce!.fetch("allowed")
      task.define_singleton_method(:base_branch) { "../unsafe" }
      assert_nil Hive::TaskCapabilities::Result.task_delta(code, sha: git(code, "rev-parse", "HEAD"), target_branch: "../unsafe")
      assert_raises(Hive::TaskCapabilities::Gate::Blocked) { gate(task, cfg, code).enforce! }
    end
  end
end
