require "test_helper"
require "hive/commands/approve"
require "hive/commands/run"
require "hive/task_closure"
require_relative "../stages/patrol_fix/fix_test"

class PatrolFixStageTransitionTest < Minitest::Test
  def test_rejected_task_moves_directly_to_archive_and_keeps_rejected_status
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, manifest|
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(
        PatrolFixStageFixture.decision_receipt(manifest, "reject")
      )
      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        Hive::PatrolFix::StageTransition.new(task).begin!("2-fix")
      end
      approve_without_enrollment(task)
      destination = File.join(task.hive_state_path, "stages", "6-done", task.slug)
      refute File.exist?(task.folder)
      assert File.directory?(destination)
      action = Hive::TaskAction.for(Hive::Task.new(destination), Hive::Markers.current(File.join(destination, "state.md")))
      assert_equal "archived", action.key
      assert_equal "Rejected", action.label
      assert_equal "rejected", action.patrol_fix.dig("outcome", "kind")
    end
  end

  def test_failed_escalation_handoff_does_not_archive_and_retries_without_an_agent
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, manifest|
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(
        PatrolFixStageFixture.decision_receipt(manifest, "escalate")
      )
      require "hive/patrol_fix/successor_materializer"
      failing = Object.new
      failing.define_singleton_method(:call) { |_| raise Hive::PatrolFix::SuccessorMaterializer::InvalidSuccessor, "handoff failed" }
      original = Hive::PatrolFix::SuccessorMaterializer.method(:new)
      Hive::PatrolFix::SuccessorMaterializer.define_singleton_method(:new) { |*| failing }
      begin
        assert_raises(Hive::PatrolFix::SuccessorMaterializer::InvalidSuccessor) do
          Hive::Commands::Approve.new(task.folder, quiet: true).call
        end
      ensure
        Hive::PatrolFix::SuccessorMaterializer.define_singleton_method(:new, original)
      end
      assert File.directory?(task.folder)
      destination = File.join(task.hive_state_path, "stages", "6-done", task.slug)
      refute File.exist?(destination)

      approve_without_enrollment(task)
      refute File.exist?(task.folder)
      action = Hive::TaskAction.for(Hive::Task.new(destination), Hive::Markers.current(File.join(destination, "state.md")))
      assert_equal "archived", action.key
      assert_equal "Escalated", action.label
      successor = action.patrol_fix.fetch("successor")
      assert_equal 1, Dir.glob(File.join(task.hive_state_path, "stages", "*", successor.fetch("slug"))).length
    end
  end

  def approve_without_enrollment(task)
    original = Hive::DependencySnapshot.method(:enforce_admission!)
    Hive::DependencySnapshot.define_singleton_method(:enforce_admission!) { |*| true }
    Hive::Commands::Approve.new(task.folder, quiet: true).call
  ensure
    Hive::DependencySnapshot.define_singleton_method(:enforce_admission!, original)
  end

  def test_crash_after_handoff_before_archive_intent_reuses_the_successor
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, manifest|
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(
        PatrolFixStageFixture.decision_receipt(manifest, "escalate")
      )
      transition = Hive::PatrolFix::StageTransition.new(task)
      transition.define_singleton_method(:append) { |_| raise "crash before intent" }
      assert_raises(RuntimeError) { transition.begin!("6-done") }
      successor = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read.dig("relations", "successor")
      assert File.directory?(task.folder)
      approve_without_enrollment(task)
      refute File.exist?(task.folder)
      destination = File.join(task.hive_state_path, "stages", "6-done", task.slug)
      assert Hive::PatrolFix::Projection.new(task_folder: destination, stage: "6-done").to_h.fetch("archived")
      assert_equal 1, Dir.glob(File.join(task.hive_state_path, "stages", "*", successor.fetch("slug"))).length
    end
  end

  def test_evidence_closure_authorizes_only_the_workflow_terminal_move
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, _manifest|
      File.write(File.join(task.folder, "closure.json"), "{}")
      valid_read = Object.new
      valid_read.define_singleton_method(:valid?) { true }
      original = Hive::TaskClosure.method(:read)
      Hive::TaskClosure.define_singleton_method(:read, ->(*) { valid_read })
      begin
        transition = Hive::PatrolFix::StageTransition.new(task)
        assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
          transition.begin!("2-fix")
        end

        intent = transition.begin!("6-done")
        assert_equal "6-done", intent.fetch("to")
      ensure
        Hive::TaskClosure.define_singleton_method(:read, original)
      end
    end
  end

  def test_unreadable_evidence_closure_cannot_authorize_the_terminal_move
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, _manifest|
      File.write(File.join(task.folder, "closure.json"), "{}")
      original = Hive::TaskClosure.method(:read)
      Hive::TaskClosure.define_singleton_method(:read) do |*|
        raise Hive::TaskClosure::InvalidReceipt, "synthetic unreadable closure"
      end
      begin
        assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
          Hive::PatrolFix::StageTransition.new(task).begin!("6-done")
        end
      ensure
        Hive::TaskClosure.define_singleton_method(:read, original)
      end
    end
  end

  def test_intent_before_move_replays_and_reconciles_after_a_crash
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, manifest|
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(
        PatrolFixStageFixture.decision_receipt(manifest, "fix")
      )
      Hive::PatrolFix::StageTransition.with_lock(task) { |transition| transition.begin!("2-fix") }
      Hive::PatrolFix::StageTransition.with_lock(task) { |transition| transition.begin!("2-fix") }
      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(task.folder, destination)
      Hive::PatrolFix::StageTransition.with_lock(Hive::Task.new(destination)) { |_transition| nil }

      journal = File.join(task.hive_state_path, "patrol-fix", "transitions", task.slug, "journal.jsonl")
      assert_equal %w[intent committed], File.readlines(journal).map { |line| JSON.parse(line).fetch("event") }
    end
  end

  def test_receipt_gated_approve_uses_a_stable_journal_outside_the_moving_folder
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, manifest|
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(
        PatrolFixStageFixture.decision_receipt(manifest, "fix")
      )
      approve_without_enrollment(task)

      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      assert File.directory?(destination)
      journal = File.join(task.hive_state_path, "patrol-fix", "transitions", task.slug, "journal.jsonl")
      rows = File.readlines(journal).map { |line| JSON.parse(line) }
      assert_equal %w[intent committed], rows.map { |row| row.fetch("event") }
      assert_equal "2-fix", rows.last.fetch("to")
    end
  end

  def test_run_enters_the_same_stable_task_lock_before_stage_execution
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, _manifest|
      command = Hive::Commands::Run.new(task.folder)
      entered = false
      observed_folder = nil
      command.define_singleton_method(:run_task) do |resolved|
        entered = true
        observed_folder = resolved.folder
        :ran
      end

      assert_equal :ran, command.send(:do_call)
      assert entered
      assert_equal task.folder, observed_folder
      assert File.file?(File.join(
        task.hive_state_path, "patrol-fix", "transitions", task.slug, ".lock"
      ))
    end
  end

  def test_pending_move_fails_closed_if_the_generation_changes_before_reconciliation
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, manifest|
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(
        PatrolFixStageFixture.decision_receipt(manifest, "fix")
      )
      Hive::PatrolFix::StageTransition.with_lock(task) { |transition| transition.begin!("2-fix") }
      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(task.folder, destination)
      changed = Hive::PatrolFix::TaskManifest.new(task_folder: destination).read
      changed = Marshal.load(Marshal.dump(changed))
      changed.fetch("task")["generation"] = 2
      changed.fetch("evidence_revision").merge!("generation" => 2, "digest" => "b" * 64)
      Hive::PatrolFix::TaskManifest.new(task_folder: destination).write!(changed)

      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        Hive::PatrolFix::StageTransition.with_lock(Hive::Task.new(destination)) { |_transition| nil }
      end
    end
  end

  def test_run_rebinds_commit_and_report_to_the_controller_moved_folder
    PatrolFixStageFixture.with_task(stage: "4-review") do |task, _root, _manifest|
      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)
      command = Hive::Commands::Run.new(task.folder, quiet: true)
      runs = 0
      committed = nil
      reported = nil
      command.define_singleton_method(:perform_rebase) { |*| Object.new }
      command.define_singleton_method(:pick_runner) do |_task|
        lambda do |_current, _cfg|
          runs += 1
          FileUtils.mkdir_p(File.dirname(destination))
          File.rename(task.folder, destination)
          { moved_task_folder: destination, status: :complete, commit: nil }
        end
      end
      command.define_singleton_method(:terminal_state_snapshot) { |_| nil }
      command.define_singleton_method(:commit_after) { |current, *| committed = current }
      command.define_singleton_method(:report) { |current, _result| reported = current }

      original = Hive::DependencySnapshot.method(:enforce_admission!)
      Hive::DependencySnapshot.define_singleton_method(:enforce_admission!) { |*| true }
      begin
        command.send(:run_task, task)
      ensure
        Hive::DependencySnapshot.define_singleton_method(:enforce_admission!, original)
      end

      assert_equal 1, runs
      assert_equal destination, committed.folder
      assert_equal destination, reported.folder
      assert_equal "fix", reported.stage_name
      assert File.file?(File.join(destination, "events.jsonl"))
      refute File.exist?(task.folder)
    end
  end

  def test_stage_event_rescue_uses_destination_when_route_commit_raises_after_move
    PatrolFixStageFixture.with_task(stage: "4-review") do |task, _root, _manifest|
      destination = File.join(task.hive_state_path, "stages", "2-fix", task.slug)

      error = assert_raises(RuntimeError) do
        Hive::Stages::Base.with_stage_events(task) do
          FileUtils.mkdir_p(File.dirname(destination))
          File.rename(task.folder, destination)
          raise "lost route commit acknowledgement"
        end
      end

      assert_equal "lost route commit acknowledgement", error.message
      assert File.file?(File.join(destination, "events.jsonl"))
      refute File.exist?(task.folder)
    end
  end

  def test_transition_journal_rejects_corrupt_and_unmatched_records
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, _manifest|
      transition = Hive::PatrolFix::StageTransition.new(task)
      FileUtils.mkdir_p(transition.root)
      journal = File.join(transition.root, "journal.jsonl")

      File.write(journal, "{\n")
      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        transition.send(:records)
      end

      valid = {
        "task" => task.slug, "generation" => 1, "evidence_digest" => "a" * 64,
        "event" => "committed", "from" => "1-inbox", "to" => "2-fix",
        "recorded_at" => Time.utc(2026, 8, 20, 12).iso8601
      }
      File.write(journal, Hive::PatrolFix.canonical_json(valid))
      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        transition.send(:pending_record)
      end

      File.write(journal, Hive::PatrolFix.canonical_json(valid.merge("event" => "unknown")))
      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        transition.send(:records)
      end

      File.write(journal, Hive::PatrolFix.canonical_json(valid.merge(
        "event" => "intent", "recorded_at" => "not-a-time"
      )))
      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        transition.send(:records)
      end

      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        transition.send(:identity_for, File.join(task.hive_state_path, "missing"))
      end
    end
  end

  def test_pending_transition_rejects_a_task_in_an_unrelated_stage
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, manifest|
      transition = Hive::PatrolFix::StageTransition.new(task)
      FileUtils.mkdir_p(transition.root)
      row = {
        "task" => task.slug, "generation" => manifest.dig("task", "generation"),
        "evidence_digest" => manifest.dig("evidence_revision", "digest"),
        "event" => "intent", "from" => "1-inbox", "to" => "2-fix",
        "recorded_at" => Time.utc(2026, 8, 20, 12).iso8601
      }
      File.write(File.join(transition.root, "journal.jsonl"), Hive::PatrolFix.canonical_json(row))
      destination = File.join(task.hive_state_path, "stages", "3-validate", task.slug)
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(task.folder, destination)

      assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
        Hive::PatrolFix::StageTransition.new(Hive::Task.new(destination)).send(:reconcile!)
      end
    end
  end

  def test_transition_store_and_parent_sync_translate_filesystem_failures
    PatrolFixStageFixture.with_task(stage: "1-inbox") do |task, _root, _manifest|
      unsafe_directory = Object.new
      unsafe_directory.define_singleton_method(:with_lock) do |*|
        raise Hive::ManagedDirectory::UnsafeError, "unsafe path"
      end
      fake = Object.new
      fake.define_singleton_method(:directory) { unsafe_directory }
      original_new = Hive::PatrolFix::StageTransition.method(:new)
      Hive::PatrolFix::StageTransition.define_singleton_method(:new, ->(*) { fake })
      begin
        assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
          Hive::PatrolFix::StageTransition.with_lock(task) { nil }
        end
      ensure
        Hive::PatrolFix::StageTransition.define_singleton_method(:new, original_new)
      end

      transition = Hive::PatrolFix::StageTransition.new(task)
      original_fsync = Hive::AtomicFile.method(:fsync_directory)
      Hive::AtomicFile.define_singleton_method(:fsync_directory, ->(*) { raise IOError, "sync failed" })
      begin
        assert_raises(Hive::PatrolFix::StageTransition::InvalidTransition) do
          transition.send(:sync_stage_parents!, "from" => "1-inbox", "to" => "2-fix")
        end
      ensure
        Hive::AtomicFile.define_singleton_method(:fsync_directory, original_fsync)
      end
    end
  end
end
