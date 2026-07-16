require "test_helper"
require "hive/attempts/reconciler"

class AttemptsReconcilerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  OWNER = {
    "pid" => 123,
    "start_fingerprint" => "start-1",
    "session_id" => 123,
    "process_group_id" => 123
  }.freeze

  FakeIdentity = Struct.new(:owner_status) do
    def status(_owner) = owner_status
  end

  def test_unclaimed_and_claimed_launch_deadlines_transition_once_to_lost
    with_store do |store|
      unclaimed = create(store, attempt_id: "unclaimed", timeout: 1)
      claimed_base = create(store, attempt_id: "claimed", timeout: 30)
      claimed = store.claim(
        claimed_base, owner: OWNER, first_heartbeat_timeout_sec: 1, now: NOW
      )
      reconciler = reconciler(store, :missing)

      first = reconciler.reconcile(now: NOW + 2)
      second = reconciler.reconcile(now: NOW + 3)

      assert_equal %w[claimed unclaimed], first.lost_attempts.map(&:attempt_id).sort
      assert_equal %w[claimed unclaimed], second.lost_attempts.map(&:attempt_id).sort
      assert_empty second.newly_lost_attempts
      assert_equal "launch_timeout", store.fetch(unclaimed.attempt_id)["loss"]["reason"]
      assert_equal "first_heartbeat_timeout", store.fetch(claimed.attempt_id)["loss"]["reason"]
    end
  end

  def test_fresh_matching_owner_is_adopted_without_waiting_on_child_status
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      snapshot = reconciler(store, :matching).reconcile(now: NOW + 2)

      status = snapshot.attempts.find { |candidate| candidate.attempt.attempt_id == running.attempt_id }
      assert_equal :adopted, status.classification
      assert_equal "running", store.fetch(running.attempt_id).state
      assert_equal 1, snapshot.capacity.global_count
    end
  end

  def test_stale_matching_owner_is_suspect_and_still_reserves_capacity
    with_store do |store|
      running = running_attempt(store, stale_sec: 1)
      snapshot = reconciler(store, :matching).reconcile(now: NOW + 5)

      status = snapshot.attempts.first
      assert_equal :suspect, status.classification
      assert_equal "running", store.fetch(running.attempt_id).state
      assert_equal [ running.attempt_id ], snapshot.capacity.reserved_attempt_ids
    end
  end

  def test_fresh_heartbeat_with_reused_or_missing_pid_is_lost_not_adopted
    %i[mismatched missing].each do |owner_status|
      with_store do |store|
        running = running_attempt(store, stale_sec: 30)
        snapshot = reconciler(store, owner_status).reconcile(now: NOW + 2)

        assert_equal [ running.attempt_id ], snapshot.newly_lost_attempts.map(&:attempt_id)
        lost = store.fetch(running.attempt_id)
        assert_equal "lost", lost.state
        expected = owner_status == :mismatched ? "owner_identity_mismatch" : "owner_gone"
        assert_equal expected, lost["loss"]["reason"]
      end
    end
  end

  def test_unverifiable_owner_fails_closed_as_suspect
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      snapshot = reconciler(store, :unverifiable).reconcile(now: NOW + 2)

      assert_empty snapshot.lost_attempts
      assert_equal :suspect, snapshot.attempts.first.classification
      assert_equal "running", store.fetch(running.attempt_id).state
      assert_equal 1, snapshot.capacity.global_count
    end
  end

  def test_valid_terminal_receipt_has_highest_precedence
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      terminal = store.terminalize(
        running, outcome: "succeeded", exit_status: 0,
        final_checkpoint: running.checkpoint,
        output_references: [],
        log_reference: { "path" => "logs/a.frames", "size" => 0, "sha256" => "0" * 64 },
        now: NOW + 2
      )

      snapshot = reconciler(store, :missing).reconcile(now: NOW + 3)

      assert_empty snapshot.lost_attempts
      assert_equal [ terminal.attempt_id ], snapshot.terminal_attempts.map(&:attempt_id)
      assert_equal :terminal, snapshot.attempts.first.classification
    end
  end

  def test_commits_alone_never_infer_success_and_matching_marker_only_records_evidence
    with_tmp_git_repo do |project_root|
      task_folder = File.join(project_root, ".hive-state", "stages", "4-execute", "durable-task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "meta.yml"), { "id" => "42" }.to_yaml)
      File.write(File.join(task_folder, "worktree.yml"), { "path" => project_root }.to_yaml)
      state_file = File.join(task_folder, "task.md")
      File.write(state_file, "# task\n")
      3.times do |index|
        File.write(File.join(project_root, "commit-#{index}.txt"), "#{index}\n")
        run!("git", "-C", project_root, "add", "commit-#{index}.txt")
        run!("git", "-C", project_root, "commit", "-m", "commit #{index}", "--quiet")
      end
      project = {
        "name" => "demo", "path" => project_root,
        "hive_state_path" => File.join(project_root, ".hive-state")
      }
      original = Hive::Config.method(:find_project)
      Hive::Config.define_singleton_method(:find_project) { |_name| project }

      with_store do |store|
        running = running_attempt(store, stale_sec: 30)
        first = reconciler(store, :missing).reconcile(now: NOW + 2)
        lost = first.lost_attempts.first
        assert_equal "git_inventory", lost["diagnostics"]["evidence_precedence"]
        assert_equal false, lost["diagnostics"].dig("git_inventory", "success_inferred")
      end

      with_store do |store|
        running = running_attempt(store, stale_sec: 30)
        Hive::Markers.set(
          state_file, :complete,
          attempt_id: running.attempt_id,
          task_generation: running.task_generation
        )
        second = reconciler(store, :missing).reconcile(now: NOW + 2)
        lost = second.lost_attempts.first
        assert_equal "lost", lost.state
        assert_equal "current_generation_marker", lost["diagnostics"]["evidence_precedence"]
        assert_equal true, lost["diagnostics"].dig("marker_evidence", "terminal")
      end
    ensure
      Hive::Config.define_singleton_method(:find_project, original) if original
    end
  end

  private

  def with_store
    with_tmp_dir { |root| yield Hive::Attempts::Store.new(root: root) }
  end

  def reconciler(store, owner_status)
    Hive::Attempts::Reconciler.new(
      store: store,
      process_identity: FakeIdentity.new(owner_status)
    )
  end

  def create(store, attempt_id: "attempt-1", timeout: 30)
    store.create_launching(
      attempt_id: attempt_id, request_id: "request-#{attempt_id}", predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: "durable-task",
      intended_stage: "4-execute", task_generation: "generation-#{attempt_id}",
      progress_token: "progress", provider: "codex", starting_revision: nil,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: timeout, now: NOW
    )
  end

  def running_attempt(store, stale_sec:)
    launching = create(store)
    claimed = store.claim(
      launching, owner: OWNER, first_heartbeat_timeout_sec: 30, now: NOW
    )
    store.first_heartbeat(claimed, stale_sec: stale_sec, now: NOW + 1)
  end
end
