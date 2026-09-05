require "test_helper"
require "hive/lock"

class LockTest < Minitest::Test
  include HiveTestHelper

  def setup
    @root = tracked_tmp_dir("hive-test-lock")
    @database = Hive::RuntimeControlPlane::Database.new(
      path: File.join(@root, "runtime.sqlite3")
    ).migrate!
    @project_id = "lock-project"
    timestamp = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
    @database.transaction do |db|
      installation = db[:installations].get(:installation_id)
      db[:projects].insert(
        project_id: @project_id, installation_id: installation,
        registration_id: @project_id, name: "lock-test", observed_path: @root,
        state_root_path: File.join(@root, ".hive-state"), active: 1,
        registered_at: timestamp, last_observed_at: timestamp
      )
    end
    Hive::Lock.task_lease_repository = repository
  end

  def teardown
    Hive::Lock.task_lease_repository = nil
    @database&.disconnect
  end

  def test_task_lease_is_reentrant_and_releases_the_typed_row
    folder = task_folder(1)
    outer = nil
    Hive::Lock.with_task_lock(folder, slug: "one") do
      outer = Hive::Lock.read_task_lock(folder)
      Hive::Lock.with_task_lock(folder, slug: "one") do
        assert_equal outer.fetch("lock_id"), Hive::Lock.read_task_lock(folder).fetch("lock_id")
        assert Hive::Lock.task_lock_held?(folder)
      end
      assert Hive::Lock.read_task_lock(folder)
    end

    assert_nil Hive::Lock.read_task_lock(folder)
    row = @database.read { |db| db[:task_leases].where(task_id: "1").first }
    assert_nil row.fetch(:holder_id)
  end

  def test_live_holder_returns_typed_contention_with_identity
    folder = task_folder(2)
    held = Hive::Lock.acquire_task_lock(folder, op: "run")

    error = assert_raises(Hive::ConcurrentRunError) do
      Hive::Lock.acquire_task_lock(folder)
    end
    assert_equal held.fetch("lock_id"), error.holder.fetch("lock_id")
    assert_equal "runtime-control-plane:task:2", error.lock_path
  ensure
    Hive::Lock.release_task_lock(folder, lock_id: held&.fetch("lock_id", nil))
  end

  def test_dead_holder_is_reclaimed_with_a_higher_fence
    folder = task_folder(3)
    first = Hive::Lock.acquire_task_lock(folder, op: "dead")
    dead = repository(process_alive: ->(*) { false })
    replacement = dead.acquire(folder, {}, create: false)

    refute_equal first.fetch("lock_id"), replacement.fetch("lock_id")
    row = @database.read { |db| db[:task_leases].where(task_id: "3").first }
    assert_equal 2, row.fetch(:lease_version)
  ensure
    Hive::Lock.release_task_lock(folder, lock_id: replacement&.fetch("lock_id", nil))
  end

  def test_pid_reuse_reclaims_holder
    folder = task_folder(4)
    old = repository(
      process_start_time: ->(*) { "old-start" },
      process_alive: ->(*) { true }
    ).acquire(folder, {}, create: false)
    replacement_repository = repository(
      process_start_time: ->(*) { "new-start" },
      process_alive: lambda { |_pid, recorded_start_time:|
        recorded_start_time == "new-start"
      }
    )

    replacement = replacement_repository.acquire(folder, {}, create: false)
    refute_equal old.fetch("lock_id"), replacement.fetch("lock_id")
  ensure
    replacement_repository&.release(folder, lock_id: replacement&.fetch("lock_id", nil))
  end

  def test_moved_task_resolves_same_lease_and_release_does_not_recreate_source
    source = task_folder(5)
    held = Hive::Lock.acquire_task_lock(source)
    destination = File.join(@root, "moved", "five")
    FileUtils.mkdir_p(File.dirname(destination))
    File.rename(source, destination)

    assert_equal held.fetch("lock_id"), Hive::Lock.read_task_lock(destination).fetch("lock_id")
    assert Hive::Lock.release_task_lock(source, lock_id: held.fetch("lock_id"))
    refute File.exist?(source)
    assert_nil Hive::Lock.read_task_lock(destination)
  end

  def test_recreated_path_never_binds_a_new_task_id_to_the_historical_subject
    folder = task_folder(10)
    held = Hive::Lock.acquire_task_lock(folder)
    assert Hive::Lock.release_task_lock(folder, lock_id: held.fetch("lock_id"))
    File.write(
      File.join(folder, "meta.yml"),
      { "id" => 11, "slug" => "task-10" }.to_yaml
    )

    error = assert_raises(Hive::RuntimeControlPlane::IdentityError) do
      Hive::Lock.acquire_task_lock(folder)
    end
    assert_equal :task_identity_conflict, error.code
    old_row = @database.read { |db| db[:task_leases].where(task_id: "10").first }
    assert_nil old_row.fetch(:holder_id)
    assert_nil @database.read { |db| db[:task_leases].where(task_id: "11").first }
  end

  def test_task_id_cannot_move_between_registered_projects
    folder = task_folder(12)
    other_root = File.join(@root, "other")
    timestamp = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
    @database.transaction do |db|
      installation = db[:installations].get(:installation_id)
      db[:projects].insert(
        project_id: "other-project", installation_id: installation,
        registration_id: "other-project", name: "other-project",
        observed_path: other_root, state_root_path: File.join(other_root, ".hive-state"),
        active: 1, registered_at: timestamp, last_observed_at: timestamp
      )
    end
    other_folder = File.join(other_root, ".hive-state", "stages", "4-execute", "task-12")
    FileUtils.mkdir_p(other_folder)
    File.write(File.join(other_folder, "meta.yml"), { "id" => 12, "slug" => "task-12" }.to_yaml)

    error = assert_raises(Hive::RuntimeControlPlane::IdentityError) do
      repository.acquire(other_folder, {}, create: false)
    end
    assert_equal :task_identity_conflict, error.code
    observed_path = @database.read do |db|
      db[:task_subjects].where(task_id: "12").get(:observed_path)
    end
    assert_equal folder, observed_path
  end

  def test_subject_registration_detects_a_concurrent_cross_project_insert
    original = task_folder(102)
    other_root = File.join(@root, "concurrent-project")
    timestamp = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
    other_project = @database.transaction do |db|
      installation = db[:installations].get(:installation_id)
      db[:projects].insert(
        project_id: "concurrent-project", installation_id: installation,
        registration_id: "concurrent-project", name: "concurrent-project",
        observed_path: other_root,
        state_root_path: File.join(other_root, ".hive-state"), active: 1,
        registered_at: timestamp, last_observed_at: timestamp
      )
      db[:projects].where(project_id: "concurrent-project").first
    end
    other_folder = File.join(
      other_root, ".hive-state", "stages", "4-execute", "concurrent-task"
    )
    FileUtils.mkdir_p(other_folder)

    error = assert_raises(Hive::RuntimeControlPlane::IdentityError) do
      repository.send(
        :register_subject, other_folder, "102",
        { id: 102, slug: "concurrent-task", workflow: "coding" }, other_project
      )
    end

    assert_equal :task_identity_conflict, error.code
    observed_path = @database.read do |db|
      db[:task_subjects].where(task_id: "102").get(:observed_path)
    end
    assert_equal original, observed_path
  end

  def test_task_id_cannot_move_to_another_slug_in_the_same_project
    original = task_folder(15)
    conflicting = File.join(File.dirname(original), "different-task")
    FileUtils.mkdir_p(conflicting)
    File.write(
      File.join(conflicting, "meta.yml"),
      { "id" => 15, "slug" => "different-task" }.to_yaml
    )

    error = assert_raises(Hive::RuntimeControlPlane::IdentityError) do
      repository.acquire(conflicting, {}, create: false)
    end
    assert_equal :task_identity_conflict, error.code
    observed = @database.read do |db|
      db[:task_subjects].where(task_id: "15").get(:observed_path)
    end
    assert_equal original, observed
  end

  def test_task_identity_resolves_under_a_registered_custom_state_root
    custom_state = File.join(@root, ".custom-state")
    @database.transaction do |db|
      db[:projects].where(project_id: @project_id).update(state_root_path: custom_state)
    end
    folder = File.join(custom_state, "stages", "4-execute", "custom-task")
    FileUtils.mkdir_p(folder)
    File.write(
      File.join(folder, "meta.yml"),
      { "id" => 13, "slug" => "custom-task" }.to_yaml
    )

    held = repository.acquire(folder, {}, create: false)

    assert_equal "13", held.fetch("task_id")
    subject = @database.read { |db| db[:task_subjects].where(task_id: "13").first }
    assert_equal @project_id, subject.fetch(:project_id)
    assert_equal folder, subject.fetch(:observed_path)
  ensure
    repository.release(folder, lock_id: held.fetch("lock_id")) if held
  end

  def test_known_task_id_cannot_be_claimed_outside_its_registered_state_root
    original = task_folder(14)
    outside = File.join(@root, "outside", "task-14")
    FileUtils.mkdir_p(outside)
    FileUtils.cp(File.join(original, "meta.yml"), File.join(outside, "meta.yml"))

    error = assert_raises(Hive::RuntimeControlPlane::IdentityError) do
      repository.acquire(outside, {}, create: false)
    end

    assert_equal :missing_project_identity, error.code
    observed = @database.read do |db|
      db[:task_subjects].where(task_id: "14").get(:observed_path)
    end
    assert_equal original, observed
    assert_nil @database.read { |db| db[:task_leases].where(task_id: "14").first }
  end

  def test_old_owner_cannot_release_replacement_generation
    folder = task_folder(6)
    old = Hive::Lock.acquire_task_lock(folder)
    assert Hive::Lock.release_task_lock(folder, lock_id: old.fetch("lock_id"))
    replacement = Hive::Lock.acquire_task_lock(folder)

    refute Hive::Lock.release_task_lock(folder, lock_id: old.fetch("lock_id"))
    assert_equal replacement.fetch("lock_id"), Hive::Lock.read_task_lock(folder).fetch("lock_id")
  ensure
    Hive::Lock.release_task_lock(folder, lock_id: replacement&.fetch("lock_id", nil))
  end

  def test_update_projects_agent_identity_into_typed_payload
    folder = task_folder(7)
    assert_raises(Hive::ConcurrentRunError) do
      Hive::Lock.update_task_lock(folder, claude_pid: 41)
    end
    Hive::Lock.with_task_lock(folder) do
      Hive::Lock.update_task_lock(folder, claude_pid: 42, claude_pid_start_time: "start")

      payload = Hive::Lock.read_task_lock(folder)
      assert_equal 42, payload.fetch("claude_pid")
      assert_equal "start", payload.fetch("claude_pid_start_time")
    end
  end

  def test_completed_child_clear_is_scoped_to_the_recorded_process_identity
    folder = task_folder(16)
    Hive::Lock.with_task_lock(folder) do
      Hive::Lock.update_task_lock(
        folder, claude_pid: 123, claude_pid_start_time: "first"
      )

      refute Hive::Lock.clear_task_lock_child(
        folder, pid: 456, process_start_time: "first"
      )
      refute Hive::Lock.clear_task_lock_child(
        folder, pid: 123, process_start_time: "replacement"
      )
      assert Hive::Lock.clear_task_lock_child(
        folder, pid: 123, process_start_time: "first"
      )

      current = Hive::Lock.read_task_lock(folder)
      refute current.key?("claude_pid")
      refute current.key?("claude_pid_start_time")
    end
  end

  def test_oversized_payloads_are_rejected_without_mutating_the_lease
    folder = task_folder(9)
    assert_raises(Hive::RuntimeControlPlane::CodecError) do
      Hive::Lock.acquire_task_lock(folder, detail: "x" * 20_000)
    end
    assert_nil @database.read { |db| db[:task_leases].where(task_id: "9").first }

    Hive::Lock.with_task_lock(folder) do
      before = Hive::Lock.read_task_lock(folder)
      assert_raises(Hive::RuntimeControlPlane::CodecError) do
        Hive::Lock.update_task_lock(folder, detail: "x" * 20_000)
      end
      assert_equal before, Hive::Lock.read_task_lock(folder)
    end
  end

  def test_fork_does_not_inherit_thread_local_task_lease_ownership
    folder = task_folder(8)
    status = nil
    Hive::Lock.with_task_lock(folder) do
      child = Hive::RuntimeControlPlane::ProcessGuard.fork do
        begin
          Hive::Lock.with_task_lock(folder) { exit! 2 }
        rescue Hive::ConcurrentRunError
          exit! 0
        end
      end
      status = Process.wait2(child).last
    end

    assert status.success?
  end

  def test_commit_lock_remains_reentrant_and_process_scoped
    directory = File.join(@root, "git-state")
    result = Hive::Lock.with_commit_lock(directory) do
      Hive::Lock.with_commit_lock(directory, timeout: 0) { :nested }
    end
    assert_equal :nested, result

    status = Hive::Lock.with_commit_lock(directory) do
      child = Hive::RuntimeControlPlane::ProcessGuard.fork do
        begin
          Hive::Lock.with_commit_lock(directory, timeout: 0.05) { exit! 2 }
        rescue Hive::ConcurrentRunError
          exit! 0
        end
      end
      Process.wait2(child).last
    end
    assert status.success?
    assert File.file?(File.join(directory, ".commit-lock"))
  end

  def test_process_start_time_helpers_remain_bounded
    assert Hive::Lock.process_start_time(Process.pid)
    assert_kind_of Numeric, Hive::Lock.monotonic_now
  end

  def test_process_identity_helpers_fail_closed_for_platform_errors
    original_exist = File.method(:exist?)
    original_read = File.method(:read)
    exist = ->(path) { path == "/proc/987654/stat" ? true : original_exist.call(path) }
    read = lambda do |path, *arguments|
      raise Errno::EACCES, path if path == "/proc/987654/stat"

      original_read.call(path, *arguments)
    end
    result = with_replaced_singleton_method(File, :exist?, exist) do
      with_replaced_singleton_method(File, :read, read) do
        Hive::Lock.proc_stat_start_time(987654)
      end
    end
    assert_nil result

    missing = ->(*) { raise Errno::ESRCH }
    denied = ->(*) { raise Errno::EPERM }
    assert_equal false, with_replaced_singleton_method(Process, :kill, missing) {
      Hive::Lock.send(:process_identity_alive?, 987654, recorded_start_time: nil)
    }
    assert_equal true, with_replaced_singleton_method(Process, :kill, denied) {
      Hive::Lock.send(:process_identity_alive?, 987654, recorded_start_time: nil)
    }
  end

  def test_ps_start_time_timeout_and_read_failures_are_bounded
    fake_pid = 987654
    spawn = ->(*, **) { fake_pid }
    wait = ->(*) { nil }
    terminated = []
    terminate = ->(pid) { terminated << pid }
    timed_out = with_replaced_singleton_method(Process, :spawn, spawn) do
      with_replaced_singleton_method(Hive::Lock, :wait_for_process, wait) do
        with_replaced_singleton_method(Hive::Lock, :terminate_and_detach, terminate) do
          Hive::Lock.ps_lstart_start_time(fake_pid)
        end
      end
    end
    assert_nil timed_out
    assert_equal [ fake_pid ], terminated

    io_failure = -> { raise IOError, "pipe failed" }
    assert_nil with_replaced_singleton_method(IO, :pipe, io_failure) {
      Hive::Lock.ps_lstart_start_time(fake_pid)
    }
  end

  def test_ps_start_time_reads_one_bounded_line
    fake_pid = 987654
    status = Struct.new(:success?).new(true)
    spawn = lambda do |*, out:, **|
      out.write("Mon Aug 31 12:00:00 2026\n")
      out.close
      fake_pid
    end
    wait = ->(*) { status }
    value = with_replaced_singleton_method(Process, :spawn, spawn) do
      with_replaced_singleton_method(Hive::Lock, :wait_for_process, wait) do
        Hive::Lock.ps_lstart_start_time(fake_pid)
      end
    end

    assert_equal "Mon Aug 31 12:00:00 2026", value
  end

  def test_process_cleanup_tolerates_disappearing_children
    missing = ->(*) { raise Errno::ESRCH }
    detached = []
    detach = ->(pid) { detached << pid }
    with_replaced_singleton_method(Process, :kill, missing) do
      with_replaced_singleton_method(Process, :detach, detach) do
        Hive::Lock.send(:terminate_and_detach, 987654)
      end
    end
    assert_equal [ 987654 ], detached

    detach_missing = ->(*) { raise Errno::ECHILD }
    with_replaced_singleton_method(Process, :detach, detach_missing) do
      assert_nil Hive::Lock.send(:terminate_and_detach, 987654)
    end
  end

  def test_missing_noncreating_lease_and_liveness_probe_errors_fail_closed
    missing = File.join(@root, ".hive-state", "stages", "4-execute", "missing")
    assert_raises(Errno::ENOENT) do
      repository.acquire(missing, {}, create: false)
    end

    folder = task_folder(99)
    subject = repository(process_alive: ->(*) { raise IOError, "probe unavailable" })
    first = subject.acquire(folder, {}, create: false)
    error = assert_raises(Hive::ConcurrentRunError) do
      subject.acquire(folder, {}, create: false)
    end
    assert_equal first.fetch("lock_id"), error.holder.fetch("lock_id")
  ensure
    subject&.release(folder, lock_id: first&.fetch("lock_id", nil))
  end

  def test_acquire_reports_contention_after_compare_and_swap_retries_are_exhausted
    folder = task_folder(100)
    subject = repository
    subject.define_singleton_method(:read_row) { |_task_id| nil }
    subject.define_singleton_method(:claim) { |_identity, _observed, _data, _payload| nil }

    error = assert_raises(Hive::ConcurrentRunError) do
      subject.acquire(folder, {}, create: false)
    end

    assert_nil error.holder
  end

  def test_unique_insert_race_retries_without_claiming_the_existing_row
    folder = task_folder(101)
    subject = repository
    identity = subject.send(:subject_for, folder, observe: true)
    timestamp = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
    @database.transaction do |db|
      db[:task_leases].insert(
        task_id: identity.fetch(:task_id), lease_version: 1,
        holder_id: nil, holder_pid: nil,
        holder_process_identity: nil, payload_json: "{}"
      )
    end
    data = {
      "started_at" => timestamp, "pid" => Process.pid,
      "process_start_time" => Hive::Lock.process_start_time(Process.pid),
      "lock_id" => "racing-owner", "task_id" => identity.fetch(:task_id)
    }

    assert_nil subject.send(:claim, identity, nil, data, subject.send(:dump_payload, data))
    holder_id = @database.read do |db|
      db[:task_leases].where(task_id: identity.fetch(:task_id)).get(:holder_id)
    end
    assert_nil holder_id
  end

  private

  def task_folder(id)
    folder = File.join(@root, ".hive-state", "stages", "4-execute", id.to_s)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "meta.yml"), { "id" => id, "slug" => "task-#{id}" }.to_yaml)
    timestamp = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
    @database.transaction do |db|
      db[:task_subjects].insert_conflict.insert(
        task_id: id.to_s, project_id: @project_id, workflow_id: "coding",
        task_slug: "task-#{id}", observed_path: folder,
        source_fingerprint: "source-#{id}", generation: 0,
        created_at: timestamp, last_observed_at: timestamp
      )
    end
    folder
  end

  def repository(process_start_time: Hive::Lock.method(:process_start_time),
                 process_alive: Hive::Lock.method(:process_identity_alive?))
    Hive::RuntimeControlPlane::TaskLeaseRepository.new(
      database: @database, process_start_time: process_start_time,
      process_alive: process_alive
    )
  end
end
