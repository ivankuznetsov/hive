require "test_helper"
require "stringio"
require "hive/one_shot/project_guard"

class OneShotProjectGuardTest < Minitest::Test
  include HiveTestHelper

  def test_live_owner_is_reported_with_typed_identity
    with_tmp_dir do |root|
      holder = guard(root, kind: "daemon").acquire!
      error = assert_raises(Hive::OneShot::ProjectGuard::OwnershipError) do
        guard(root, kind: "one_shot").acquire!
      end

      assert_equal "daemon_owned", error.code
      assert_equal "daemon", error.owner.fetch("kind")
      assert_equal Process.pid, error.owner.fetch("pid")
      assert_equal Hive::Lock.process_start_time(Process.pid),
                   error.owner.fetch("process_identity")
    ensure
      holder&.release!
    end
  end

  def test_aliases_share_one_canonical_guard
    with_tmp_dir do |root|
      state = File.join(root, "state")
      FileUtils.mkdir_p(state)
      alias_path = File.join(root, "alias")
      File.symlink(state, alias_path)
      holder = guard(state, kind: "one_shot").acquire!

      error = assert_raises(Hive::OneShot::ProjectGuard::OwnershipError) do
        guard(alias_path, kind: "babysitter").acquire!
      end

      assert_equal "one_shot_busy", error.code
      assert_equal holder.path, guard(alias_path, kind: "one_shot").path
    ensure
      holder&.release!
    end
  end

  def test_babysitter_guard_coexists_with_main_daemon_but_excludes_another_babysitter
    with_tmp_dir do |root|
      daemon = guard(root, kind: "daemon").acquire!
      babysitter = Hive::OneShot::ProjectGuard.new(
        state_root: root, project: "demo", kind: :babysitter,
        lock_name: "babysitter-execution.lock"
      ).acquire!

      error = assert_raises(Hive::OneShot::ProjectGuard::OwnershipError) do
        Hive::OneShot::ProjectGuard.new(
          state_root: root, project: "demo", kind: :babysitter,
          lock_name: "babysitter-execution.lock"
        ).acquire!
      end
      assert_equal "babysitter_owned", error.code
    ensure
      babysitter&.release!
      daemon&.release!
    end
  end

  def test_unreadable_owner_metadata_fails_closed
    with_tmp_dir do |root|
      holder = guard(root, kind: "daemon").acquire!
      File.binwrite(holder.path, "not-json")

      error = assert_raises(Hive::OneShot::ProjectGuard::OwnershipError) do
        guard(root, kind: "one_shot").acquire!
      end

      assert_equal "ownership_unverifiable", error.code
      assert_nil error.owner
    ensure
      holder&.release!
    end
  end

  def test_process_death_releases_guard_without_deleting_stable_inode
    with_tmp_dir do |root|
      ready_r, ready_w = IO.pipe
      release_r, release_w = IO.pipe
      pid = fork do
        ready_r.close
        release_w.close
        child = guard(root, kind: "daemon").acquire!
        ready_w.write("1")
        ready_w.close
        release_r.read(1)
        child.release!
        exit! 0
      end
      ready_w.close
      release_r.close
      assert_equal "1", ready_r.read(1)
      assert_raises(Hive::OneShot::ProjectGuard::OwnershipError) do
        guard(root, kind: "one_shot").acquire!
      end
      release_w.write("1")
      release_w.close
      Process.wait(pid)

      acquired = guard(root, kind: "one_shot").acquire!
      assert File.file?(acquired.path)
      assert acquired.release!
      assert File.file?(acquired.path)
    ensure
      release_w&.close unless release_w&.closed?
      Process.kill("KILL", pid) if pid && process_alive?(pid)
      Process.wait(pid) if pid && process_alive?(pid)
    end
  end

  def test_process_guard_closes_inherited_descriptor_in_child
    with_tmp_dir do |root|
      parent = guard(root, kind: "daemon").acquire!
      ready_r, ready_w = IO.pipe
      release_r, release_w = IO.pipe
      pid = Hive::RuntimeControlPlane::ProcessGuard.fork do
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
      parent.release!

      contender = guard(root, kind: "one_shot").acquire!
      assert contender.release!
      release_w.write("1")
      release_w.close
      Process.wait(pid)
    ensure
      parent&.release!
      release_w&.close unless release_w&.closed?
      Process.kill("KILL", pid) if pid && process_alive?(pid)
      Process.wait(pid) if pid && process_alive?(pid)
    end
  end

  def test_collection_acquires_newly_enabled_projects_and_defers_contended_ones
    with_tmp_dir do |root|
      one = File.join(root, "one")
      two = File.join(root, "two")
      entries = [
        { "name" => "one", "path" => one, "hive_state_path" => File.join(one, ".hive-state") },
        { "name" => "two", "path" => two, "hive_state_path" => File.join(two, ".hive-state") }
      ]
      entries.each { |entry| FileUtils.mkdir_p(entry.fetch("hive_state_path")) }
      enabled = { "one" => true, "two" => false }
      collection = Hive::OneShot::ProjectGuard::Collection.new(
        kind: "daemon", registry: -> { entries },
        enabled: ->(entry) { enabled.fetch(entry.fetch("name")) }
      )

      assert_equal %w[one], collection.refresh!
      contender = guard(entries.last.fetch("hive_state_path"), kind: "one_shot").acquire!
      enabled["two"] = true
      assert_equal %w[one], collection.refresh!
      assert_equal "one_shot_busy", collection.contentions.fetch("two").code

      contender.release!
      assert_equal %w[one two], collection.refresh!.sort
      collection.release_all!
      assert_empty collection.owned_projects
    ensure
      contender&.release!
      collection&.release_all!
    end
  end

  def test_rejects_unsafe_lock_names_and_reports_its_live_owner
    with_tmp_dir do |root|
      assert_raises(ArgumentError) do
        Hive::OneShot::ProjectGuard.new(
          state_root: root, project: "demo", kind: :one_shot, lock_name: "../lock"
        )
      end

      active = guard(root, kind: "one_shot").acquire!
      assert_equal "one_shot", active.owner.fetch("kind")
      assert active.release!
      assert_nil active.owner
    end
  end

  def test_guard_io_failures_are_typed
    with_tmp_dir do |root|
      acquiring = guard(root, kind: "one_shot")
      acquiring.define_singleton_method(:open_handle) { raise IOError, "closed" }
      error = assert_raises(Hive::ConfigError) { acquiring.acquire! }
      assert_match(/guard is unavailable/, error.message)

      releasing = guard(root, kind: "one_shot").acquire!
      handle = releasing.instance_variable_get(:@handle)
      handle.define_singleton_method(:flock) { |*| raise IOError, "closed" }
      error = assert_raises(Hive::ConfigError) { releasing.release! }
      assert_match(/could not be released/, error.message)
      handle.close unless handle.closed?
    end
  end

  def test_owner_validation_and_process_probes_fail_closed
    with_tmp_dir do |root|
      current = guard(root, kind: "one_shot")
      assert_nil current.send(:verified_owner, StringIO.new("{}"))

      with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::EPERM }) do
        assert current.send(:process_alive?, Process.pid)
      end
      with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
        refute current.send(:process_alive?, Process.pid)
      end
    end
  end

  private

  def guard(root, kind:)
    Hive::OneShot::ProjectGuard.new(state_root: root, project: "app", kind: kind)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::ECHILD
    false
  end
end
