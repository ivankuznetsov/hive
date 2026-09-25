require "test_helper"
require "hive/one_shot/project_liveness"
require "hive/one_shot/runner"

class OneShotProjectLivenessTest < Minitest::Test
  include HiveTestHelper

  Attempt = Struct.new(:project, :live) do
    def [](key) = key == "project" ? project : nil
    def live? = live
  end

  class AttemptStore
    attr_accessor :attempts
    def initialize(attempts = []) = @attempts = attempts
    def active_attempts = attempts
  end

  class LeaseRepository
    attr_accessor :leases
    def initialize(leases = []) = @leases = leases
    def active_leases(**) = leases
  end

  class ArchitectureStore
    attr_accessor :jobs
    def initialize(jobs = []) = @jobs = jobs
  end

  class LifecycleDispatcher
    attr_reader :one_shot_ran

    def initialize(liveness)
      @liveness = liveness
      @one_shot_ran = []
    end

    def run_one_shot(**)
      { ran: [], items: [], safe_to_stop: @liveness.safe_to_stop? }
    end
  end

  def test_durable_attempt_or_live_task_worker_withholds_stop_safety
    with_tmp_dir do |root|
      store = AttemptStore.new([ Attempt.new("demo", true) ])
      leases = LeaseRepository.new
      liveness = liveness(root, attempt_store: store, lease_repository: leases)
      refute liveness.safe_to_stop?

      store.attempts = []
      leases.leases = [ lease(Process.pid, Hive::Lock.process_start_time(Process.pid)) ]
      refute liveness.safe_to_stop?

      leases.leases = []
      assert liveness.safe_to_stop?
    end
  end

  def test_malformed_or_unbounded_lease_observation_fails_closed
    with_tmp_dir do |root|
      malformed = LeaseRepository.new([ { malformed: true, payload: nil } ])
      refute liveness(root, lease_repository: malformed).safe_to_stop?

      overflow = LeaseRepository.new(
        Array.new(Hive::OneShot::ProjectLiveness::MAX_LEASES + 1) { lease(999_999, "gone") }
      )
      refute liveness(root, lease_repository: overflow).safe_to_stop?
    end
  end

  def test_live_pid_with_missing_or_unreadable_identity_fails_closed
    with_tmp_dir do |root|
      missing = LeaseRepository.new([ lease(Process.pid, nil) ])
      refute liveness(root, lease_repository: missing).safe_to_stop?

      unreadable = LeaseRepository.new([ lease(Process.pid, "recorded") ])
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(*) { }) do
        refute liveness(root, lease_repository: unreadable).safe_to_stop?
      end
    end
  end

  def test_active_architecture_discovery_claim_withholds_stop_safety
    with_tmp_dir do |root|
      store = ArchitectureStore.new([
        {
          "attempts" => [
            { "kind" => "discovery_claim", "state" => "running",
              "pid" => Process.pid,
              "process_start_time" => Hive::Lock.process_start_time(Process.pid) }
          ]
        }
      ])

      refute liveness(root, architecture_store: store).safe_to_stop?

      store.jobs.first.fetch("attempts").last["state"] = "finished"
      assert liveness(root, architecture_store: store).safe_to_stop?
    end
  end

  def test_unreadable_architecture_claim_authority_fails_closed
    with_tmp_dir do |root|
      store = Object.new
      store.define_singleton_method(:jobs) { raise IOError, "unreadable" }

      refute liveness(root, architecture_store: store).safe_to_stop?
    end
  end

  def test_runner_reports_stop_safe_only_after_controlled_worker_exits
    with_tmp_dir do |root|
      ready_r, ready_w = IO.pipe
      release_r, release_w = IO.pipe
      pid = fork do
        ready_r.close
        release_w.close
        ready_w.write("1")
        ready_w.close
        release_r.read(1)
        exit! 0
      end
      ready_w.close
      release_r.close
      assert_equal "1", ready_r.read(1)

      leases = LeaseRepository.new([ lease(pid, Hive::Lock.process_start_time(pid)) ])
      probe = liveness(root, lease_repository: leases)
      runner = Hive::OneShot::Runner.new(
        dispatcher: LifecycleDispatcher.new(probe), project: "demo"
      )
      refute runner.call.fetch(:safe_to_stop)

      release_w.write("1")
      release_w.close
      Process.wait(pid)
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      assert runner.call.fetch(:safe_to_stop)
    ensure
      release_w&.close unless release_w&.closed?
      Process.kill("KILL", pid) if pid && process_alive?(pid)
      Process.wait(pid) if pid && process_alive?(pid)
    end
  end

  private

  def liveness(root, attempt_store: AttemptStore.new, lease_repository: LeaseRepository.new,
               architecture_store: ArchitectureStore.new)
    Hive::OneShot::ProjectLiveness.new(
      entry: { "name" => "demo", "hive_state_path" => root },
      attempt_store: attempt_store, lease_repository: lease_repository,
      architecture_store: architecture_store
    )
  end

  def lease(pid, identity)
    {
      malformed: false,
      payload: { "pid" => pid, "process_start_time" => identity }
    }
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::ECHILD
    false
  end
end
