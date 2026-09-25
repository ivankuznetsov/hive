require "test_helper"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/launch_fence"

class RuntimeControlPlaneQuiescenceLifecycleTest < Minitest::Test
  include HiveTestHelper

  def test_fresh_database_starts_running_and_retries_same_generation
    with_database do |database|
      repository = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)

      initial = repository.current
      assert_equal "running", initial.phase
      assert initial.admission_open?
      assert_equal 0, initial.generation

      first = repository.begin_quiesce!(
        deadline_monotonic: 700.0, boot_id: "boot-a", shutdown_grace_sec: 120.0,
        now: Time.utc(2026, 9, 25, 12)
      )
      retry_state = repository.begin_quiesce!(
        deadline_monotonic: 900.0, boot_id: "boot-a", shutdown_grace_sec: 200.0,
        now: Time.utc(2026, 9, 25, 12, 1)
      )

      assert_equal "quiescing", first.phase
      refute first.admission_open?
      assert_equal 1, first.generation
      assert_equal first, retry_state
      assert_equal 700.0, retry_state.deadline_monotonic
    end
  end

  def test_stale_controller_cannot_publish_paused_after_resume
    with_database do |database|
      repository = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      quiescing = repository.begin_quiesce!(
        deadline_monotonic: 700.0, boot_id: "boot-a", shutdown_grace_sec: 120.0
      )
      resuming = repository.begin_resume!(generation: quiescing.generation)
      running = repository.reopen!(
        generation: resuming.generation, expected_revision: resuming.revision
      )

      assert_equal "running", running.phase
      assert running.admission_open?
      assert_raises(Hive::RuntimeControlPlane::StaleLifecycle) do
        repository.mark_paused!(
          generation: quiescing.generation, expected_revision: quiescing.revision,
          interrupted_attempt_ids: []
        )
      end
    end
  end

  def test_ordinary_writes_are_denied_after_admission_closes
    with_database do |database|
      repository = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      repository.begin_quiesce!(
        deadline_monotonic: 700.0, boot_id: "boot-a", shutdown_grace_sec: 120.0
      )

      error = assert_raises(Hive::RuntimeControlPlane::AdmissionClosed) do
        database.transaction { |db| db[:installations].update(activation_epoch: 2) }
      end
      assert_equal :admission_closed, error.code

      database.with_exclusive_writer(role: :controller, timeout_sec: 0.5) do |authority|
        database.transaction(authority: authority) do |db|
          db[:installations].update(activation_epoch: 2)
        end
      end
      assert_equal 2, database.read { |db| db[:installations].get(:activation_epoch) }
    end
  end

  def test_checkpoint_reports_busy_and_checkpointed_frames
    with_database do |database|
      result = database.checkpoint!(timeout_sec: 1)

      assert_equal true, result.fetch(:complete)
      assert_operator result.fetch(:checkpointed_frames), :>=, 0
      assert_operator result.fetch(:log_frames), :>=, 0
    end
  end

  def test_launch_fence_supports_shared_launchers_and_bounded_exclusive_wait
    with_tmp_dir do |root|
      first = Hive::RuntimeControlPlane::LaunchFence.new(state_home: root, timeout_sec: 0)
      second = Hive::RuntimeControlPlane::LaunchFence.new(state_home: root, timeout_sec: 0)

      first.acquire_shared!
      second.acquire_shared!
      contender = Hive::RuntimeControlPlane::LaunchFence.new(state_home: root, timeout_sec: 0)
      assert_raises(Hive::ConcurrentRunError) { contender.acquire_exclusive! }

      second.release!
      first.release!
      assert contender.acquire_exclusive!
      assert contender.exclusive?
    ensure
      contender&.release!
      second&.release!
      first&.release!
    end
  end

  def test_quiescence_paths_are_canonical
    with_tmp_dir do |root|
      assert_equal File.join(root, ".runtime-launch.lock"), Hive::Paths.runtime_launch_fence_path(root)
      assert_equal File.join(root, "runtime-quiescence-proof.json"),
                   Hive::Paths.runtime_quiescence_proof_path(root)
    end
  end

  private

  def with_database
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      yield database
    ensure
      database&.disconnect
    end
  end
end
