require "test_helper"
require "hive/patrol_fix/transition"
require_relative "../stages/patrol_fix/fix_test"

class PatrolFixTransitionTest < Minitest::Test
  def test_rework_persists_intent_advances_generation_rotates_custody_and_moves_same_task
    with_review_task(route: "rework") do |task, worktree_root, decision|
      commits = []
      transition = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root,
        commit: ->(**values) { commits << values }
      )

      result = transition.apply_review!(decision)

      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      assert_equal destination, result.fetch(:task_folder)
      assert File.directory?(destination)
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: destination).read
      assert_equal 2, manifest.dig("task", "generation")
      refute_equal "a" * 64, manifest.dig("evidence_revision", "digest")
      owner = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: destination, project_root: task.project_root, slug: task.slug,
        worktree_root: worktree_root
      ).read
      assert_equal 2, owner.fetch("generation")
      assert File.file?(File.join(destination, "patrol-fix-worktrees", "generation-1.json"))
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: destination).read_all
      authorization = receipts.find { |row| row["kind"] == "reopen" && row.dig("task", "generation") == 2 }
      assert_equal decision.fetch("receipt_id"), authorization.dig("payload", "outcome_receipt_id")
      assert_equal 1, commits.length
    end
  end

  def test_rework_recovery_runs_fix_from_controller_authorization_without_a_second_review
    with_review_task(route: "rework") do |task, worktree_root, decision|
      result = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { :committed }
      ).apply_review!(decision)
      moved = Hive::Task.new(result.fetch(:task_folder))
      runner = lambda do |**values|
        assert_includes values.fetch(:prompt), "Independent review decision."
        assert_includes values.fetch(:prompt), "Validation is current."
        worktree = values.fetch(:owner).fetch("worktree")
        File.write(File.join(worktree, "app.rb"), "puts :reworked\n")
        PatrolFixStageFixture.git(worktree, "add", "app.rb")
        PatrolFixStageFixture.git(worktree, "commit", "-m", "Rework")
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
          "status" => "fixed", "summary" => "Reworked current patch.",
          "validation_commands" => []
        ))
        { status: :ok, custody: :clean }
      end

      fixed = Hive::Stages::PatrolFix::Fix.run!(
        moved, {}, agent_runner: runner, worktree_root: worktree_root
      )

      assert_equal :complete, fixed.fetch(:status)
      assert_equal 2, fixed.dig(:receipt, "task", "generation")
      assert_equal "reworked", File.read(File.join(
        fixed.dig(:receipt, "payload", "worktree"), "app.rb"
      )).match(/:(\w+)/)[1]
    end
  end

  def test_rework_rejects_an_unchanged_patch_and_validation_commands
    with_review_task(route: "rework") do |task, worktree_root, decision|
      result = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { :committed }
      ).apply_review!(decision)
      moved = Hive::Task.new(result.fetch(:task_folder))
      retained_owner = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: moved.folder, project_root: moved.project_root, slug: moved.slug,
        worktree_root: worktree_root
      ).read
      runner = lambda do |**values|
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
          "status" => "fixed", "summary" => "Returned the existing patch.",
          "validation_commands" => []
        ))
        { status: :ok, custody: :clean }
      end

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Fix.run!(
          moved, {}, agent_runner: runner, worktree_root: worktree_root
        )
      end

      assert_includes error.message, "rework did not change the patch or validation commands"
      current = Hive::PatrolFix::ReceiptStore.new(task_folder: moved.folder).read_all.select do |row|
        row["kind"] == "fix" && row.dig("task", "generation") == 2
      end
      assert_empty current
      assert_equal retained_owner, Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: moved.folder, project_root: moved.project_root, slug: moved.slug,
        worktree_root: worktree_root
      ).read
    end
  end

  def test_rework_rejects_a_review_reference_without_prior_fix_evidence
    with_review_task(route: "rework") do |task, worktree_root, decision|
      result = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { :committed }
      ).apply_review!(decision)
      moved = Hive::Task.new(result.fetch(:task_folder))
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: moved.folder)
      File.write(
        receipts.path,
        File.read(receipts.path).sub(
          '"fix_receipt_id":"fix-1"', '"fix_receipt_id":"missing-fix"'
        )
      )

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Fix.run!(
          moved, {}, agent_runner: ->(**) { flunk "must not launch without prior Fix evidence" },
          worktree_root: worktree_root
        )
      end

      assert_includes error.message, "does not reference prior fix evidence"
      current = receipts.read_all.select do |row|
        row["kind"] == "fix" && row.dig("task", "generation") == 2
      end
      assert_empty current
    end
  end

  def test_rework_rejects_a_foreign_prior_fix_before_agent_launch
    with_review_task(route: "rework") do |task, worktree_root, decision|
      result = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { :committed }
      ).apply_review!(decision)
      moved = Hive::Task.new(result.fetch(:task_folder))
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: moved.folder)
      rows = File.readlines(receipts.path, chomp: true).map { |line| JSON.parse(line) }
      foreign = rows.find { |row| row["receipt_id"] == "fix-1" }
      foreign.fetch("task")["generation"] = 9
      foreign.fetch("evidence_revision")["generation"] = 9
      File.write(receipts.path, rows.map { |row| Hive::PatrolFix.canonical_json(row) }.join)

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Fix.run!(
          moved, {}, agent_runner: ->(**) { flunk "must not launch against foreign evidence" },
          worktree_root: worktree_root
        )
      end

      assert_includes error.message, "does not reference prior fix evidence"
    end
  end

  def test_rework_can_correct_validation_commands_without_changing_the_patch
    with_review_task(route: "rework") do |task, worktree_root, decision|
      result = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { :committed }
      ).apply_review!(decision)
      moved = Hive::Task.new(result.fetch(:task_folder))
      runner = lambda do |**values|
        File.write(values.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
          "status" => "fixed", "summary" => "Corrected the validation command.",
          "validation_commands" => [
            { "identity" => "focused", "command" => "ruby -c app.rb" }
          ]
        ))
        { status: :ok, custody: :clean }
      end

      fixed = Hive::Stages::PatrolFix::Fix.run!(
        moved, {}, agent_runner: runner, worktree_root: worktree_root
      )

      assert_equal :complete, fixed.fetch(:status)
      assert_equal "ruby -c app.rb",
                   fixed.dig(:receipt, "payload", "validation_commands", 0, "command")
    end
  end

  def test_stale_review_cannot_transition_a_newer_generation
    with_review_task(route: "rework") do |task, worktree_root, decision|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder)
      newer = Marshal.load(Marshal.dump(store.read))
      newer.fetch("task")["generation"] = 2
      newer.fetch("evidence_revision").merge!("generation" => 2, "digest" => "b" * 64)
      store.write!(newer)

      error = assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        Hive::PatrolFix::Transition.new(
          task, worktree_root: worktree_root, commit: ->(**) { flunk "must not commit" }
        ).apply_review!(decision)
      end

      assert_includes error.message, "stale"
      assert_equal 2, store.read.dig("task", "generation")
      refute File.exist?(File.join(
        task.hive_state_path, "patrol-fix", "transitions", task.slug, "route-intent.json"
      ))
    end
  end

  def test_crash_after_generation_advance_and_folder_move_reconciles_without_redeciding
    with_review_task(route: "rework") do |task, worktree_root, decision|
      attempts = 0
      crashing_commit = lambda do |**|
        attempts += 1
        raise "crash before route acknowledgement" if attempts == 1
      end
      transition = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: crashing_commit
      )

      assert_raises(RuntimeError) { transition.apply_review!(decision) }
      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      assert File.directory?(destination)
      assert_equal 2, Hive::PatrolFix::TaskManifest.new(task_folder: destination).read.dig("task", "generation")

      recovered = Hive::PatrolFix::Transition.new(
        Hive::Task.new(destination), worktree_root: worktree_root,
        commit: ->(**) { attempts += 1 }
      ).reconcile!

      assert_equal destination, recovered.fetch(:task_folder)
      assert_equal 2, attempts
      receipts = Hive::PatrolFix::ReceiptStore.new(task_folder: destination).read_all
      assert_equal 1, receipts.count { |row| row["kind"] == "reopen" }
      intent = JSON.parse(File.read(File.join(
        task.hive_state_path, "patrol-fix", "transitions", task.slug, "route-intent.json"
      )))
      assert_equal "completed", intent.fetch("status")
    end
  end

  def test_pending_intents_replay_idempotently_and_reject_competing_routes
    PatrolFixStageFixture.with_task(stage: "4-review") do |task, _root, _manifest|
      transition = Hive::PatrolFix::Transition.new(task, commit: ->(**) { })
      intent = route_intent(task)
      transition.define_singleton_method(:read_intent) { intent }
      applied = nil
      transition.define_singleton_method(:apply_intent) { |value| applied = value; :replayed }

      assert_equal :replayed, transition.reconcile!
      assert_equal intent, applied
      assert_equal intent, transition.send(
        :begin_intent, action_id: intent.fetch("action_id"), route: "rework",
        stage: "review", destination: "2-fix", operator: "controller:review",
        carried_receipts: []
      )
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(
          :begin_intent, action_id: "other-decision", route: "rework",
          stage: "review", destination: "2-fix", operator: "controller:review",
          carried_receipts: []
        )
      end
    end
  end

  def test_generation_replay_rejects_changed_or_unrecoverable_evidence
    PatrolFixStageFixture.with_task(stage: "4-review") do |task, _root, _manifest|
      transition = Hive::PatrolFix::Transition.new(task, commit: ->(**) { })
      changed = route_intent(task).merge("from_digest" => "b" * 64)
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:apply_intent, changed)
      end
    end

    PatrolFixStageFixture.with_task(stage: "4-review") do |task, _root, _manifest|
      manifest_store = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder)
      advanced = Marshal.load(Marshal.dump(manifest_store.read))
      advanced.fetch("task")["generation"] = 2
      advanced.fetch("evidence_revision").merge!("generation" => 2, "digest" => "b" * 64)
      manifest_store.write!(advanced)
      transition = Hive::PatrolFix::Transition.new(task, commit: ->(**) { })
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:apply_intent, route_intent(task).merge("to_digest" => "c" * 64))
      end

      File.write(manifest_store.path, "not-json")
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:apply_intent, route_intent(task))
      end
    end
  end

  def test_custody_and_task_move_must_match_the_intent_generation
    with_review_task(route: "rework") do |task, worktree_root, _decision|
      transition = Hive::PatrolFix::Transition.new(
        task, worktree_root: worktree_root, commit: ->(**) { }
      )
      intent = route_intent(task).merge(
        "from_generation" => 2, "to_generation" => 3,
        "from_digest" => "b" * 64, "to_digest" => "c" * 64
      )
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:rotate_worktree!, task.folder, intent)
      end

      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:move_if_needed!, task.folder, route_intent(task).merge("from" => "1-inbox"))
      end

      original_rename = File.method(:rename)
      File.define_singleton_method(:rename, ->(*) { raise IOError, "move failed" })
      begin
        assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
          transition.send(:move_if_needed!, task.folder, route_intent(task))
        end
      ensure
        File.define_singleton_method(:rename, original_rename)
      end
    end
  end

  def test_intent_store_and_decision_validation_fail_closed
    PatrolFixStageFixture.with_task(stage: "4-review") do |task, _root, _manifest|
      transition = Hive::PatrolFix::Transition.new(task, commit: ->(**) { })
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:validate_decision!, {}, route: "rework")
      end
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:validate_intent, route_intent(task).merge("route" => "unknown"))
      end
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:validate_intent, route_intent(task).merge("recorded_at" => "bad"))
      end

      FileUtils.mkdir_p(transition.instance_variable_get(:@directory).root)
      File.write(
        File.join(transition.instance_variable_get(:@directory).root,
                  Hive::PatrolFix::Transition::INTENT_FILENAME),
        "{"
      )
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:read_intent)
      end

      unsafe = Object.new
      unsafe.define_singleton_method(:read) { |*| raise Hive::ManagedDirectory::UnsafeError, "unsafe" }
      transition.instance_variable_set(:@directory, unsafe)
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:read_intent)
      end
      unsafe.define_singleton_method(:atomic_write) { |*| raise Hive::ManagedDirectory::UnsafeError, "unsafe" }
      assert_raises(Hive::PatrolFix::Transition::InvalidTransition) do
        transition.send(:write_intent, route_intent(task))
      end
    end
  end

  def test_default_commit_delegates_to_git_ops
    PatrolFixStageFixture.with_task(stage: "4-review") do |task, _root, _manifest|
      commits = []
      fake_git = Object.new
      fake_git.define_singleton_method(:hive_commit) { |**values| commits << values }
      original_new = Hive::GitOps.method(:new)
      Hive::GitOps.define_singleton_method(:new, ->(*) { fake_git })
      begin
        transition = Hive::PatrolFix::Transition.new(task)
        transition.send(:commit_intent!, route_intent(task))
      ensure
        Hive::GitOps.define_singleton_method(:new, original_new)
      end

      assert_equal "review rework", commits.fetch(0).fetch(:action)
    end
  end

  private

  def with_review_task(route:)
    PatrolFixStageFixture.with_task(stage: "4-review") do |task, root, manifest|
      store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)
      store.append!(PatrolFixStageFixture.decision_receipt(manifest, "fix"))
      worktree_root = File.join(root, "worktrees")
      custody = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root, slug: task.slug,
        worktree_root: worktree_root
      )
      owner = custody.prepare!(
        generation: 1, evidence_digest: "a" * 64,
        base_revision: manifest.fetch("target_revision")
      )
      File.write(File.join(owner.fetch("worktree"), "app.rb"), "puts :fixed\n")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "add", "app.rb")
      PatrolFixStageFixture.git(owner.fetch("worktree"), "commit", "-m", "Fix")
      fix_payload = custody.capture!(generation: 1, evidence_digest: "a" * 64)
                           .merge("validation_commands" => [])
      fix = receipt(manifest, "fix", "fix", fix_payload, "fix-1")
      store.append!(fix)
      validation_payload = { "verdict" => "failed", "worktree_head" => fix_payload.fetch("head_revision"), "commands" => [] }
      store.append!(receipt(manifest, "validation", "validate", validation_payload, "validation-1"))
      decision = receipt(
        manifest, "decision", "review",
        {
          "route" => route, "rationale" => "Independent review decision.",
          "evidence" => [ "Validation is current." ], "blocker_owner" => "review_gate",
          "head_revision" => fix_payload.fetch("head_revision"),
          "diff_digest" => fix_payload.fetch("diff_digest"),
          "fix_receipt_id" => "fix-1", "validation_receipt_id" => "validation-1"
        },
        "review-#{route}-1"
      )
      store.append!(decision)
      yield task, worktree_root, decision
    end
  end

  def receipt(manifest, kind, stage, payload, id)
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => id, "kind" => kind, "stage" => stage,
      "task" => manifest.fetch("task"),
      "evidence_revision" => manifest.fetch("evidence_revision"),
      "recorded_at" => "2026-08-20T12:00:00Z", "payload" => payload
    }
  end

  def route_intent(task)
    {
      "schema" => Hive::PatrolFix::Transition::SCHEMA,
      "schema_version" => Hive::PatrolFix::Transition::SCHEMA_VERSION,
      "status" => "pending", "task" => task.slug,
      "action_id" => "review-rework-1", "route" => "rework", "stage" => "review",
      "from" => "4-review", "to" => "2-fix", "from_generation" => 1,
      "to_generation" => 2, "from_digest" => "a" * 64, "to_digest" => "b" * 64,
      "operator" => "controller:review", "carried_receipts" => [],
      "recorded_at" => "2026-08-20T12:00:00Z"
    }
  end
end
