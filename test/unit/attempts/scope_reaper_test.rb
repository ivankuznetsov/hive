require "test_helper"
require "hive/attempts/scope_reaper"

# Every case runs against a fabricated /proc and cgroup tree with an
# in-memory signaller: no real process is ever signalled, and no systemd
# unit is created or stopped.
class AttemptsScopeReaperTest < Minitest::Test
  include HiveTestHelper

  ATTEMPT_ID = "attempt-1".freeze
  SUPERVISOR = 100

  # A scope whose members leave cgroup.procs when signalled, unless they
  # ignore that signal. Pids "outside" live in another cgroup.
  class FakeHost
    attr_reader :signals

    def initialize(root, unit:)
      @proc = File.join(root, "proc")
      @cgroup = File.join(root, "cgroup")
      @scope = "/user.slice/user-1000.slice/user@1000.service/app.slice/#{unit}"
      @members = Hash.new { |hash, key| hash[key] = [] }
      @ignores = {}
      @spawn_on_term = nil
      @signals = []
      FileUtils.mkdir_p(File.join(@cgroup, @scope))
      write_members
    end

    attr_reader :scope

    def proc_root = @proc
    def cgroup_root = @cgroup

    def add(pid, comm:, cgroup: "", ignores: [])
      path = "#{@scope}#{cgroup}"
      @members[path] << pid
      @ignores[pid] = ignores
      write_proc(pid, path, comm)
      write_members
    end

    def place_outside(pid, path)
      write_proc(pid, path, "outsider")
    end

    def spawn_on_term(pid, comm:)
      @spawn_on_term = [ pid, comm ]
    end

    def signaller
      lambda do |signal, pid|
        @signals << [ signal, pid ]
        raise Errno::ESRCH if pid == 404
        raise Errno::EPERM if pid == 403
        if signal == "TERM" && @spawn_on_term
          spawned, comm = @spawn_on_term
          @spawn_on_term = nil
          add(spawned, comm: comm)
        end
        next if @ignores.fetch(pid, []).include?(signal)

        @members.each_value { |pids| pids.delete(pid) }
        write_members
      end
    end

    def write_proc(pid, path, comm)
      directory = File.join(@proc, pid.to_s)
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "cgroup"), "0::#{path}\n")
      File.write(File.join(directory, "comm"), "#{comm}\n") if comm
    end

    def write_members
      root = [ SUPERVISOR ] + @members.fetch(@scope, [])
      File.write(File.join(@cgroup, @scope, "cgroup.procs"), root.map { |pid| "#{pid}\n" }.join)
      @members.each do |path, pids|
        next if path == @scope

        FileUtils.mkdir_p(File.join(@cgroup, path))
        File.write(File.join(@cgroup, path, "cgroup.procs"), pids.map { |pid| "#{pid}\n" }.join)
      end
    end
  end

  def test_unit_name_matches_the_launcher_scope_name
    expected = "hive-attempt-#{Digest::SHA256.hexdigest(ATTEMPT_ID)[0, 24]}"
    assert_equal expected, Hive::Attempts::ScopeReaper.unit_name(ATTEMPT_ID)
  end

  def test_a_supervisor_outside_its_own_scope_is_a_no_op
    with_host do |host, reaper|
      host.write_proc(SUPERVISOR, "/user.slice/app.slice/other.scope", "hive")
      host.add(200, comm: "conmon")

      result = reaper.call.reap(term_grace_sec: 1)

      assert_equal "unscoped", result.status
      refute result.notable?
      assert_empty host.signals
    end
  end

  def test_another_attempts_scope_and_a_sub_cgroup_are_not_ours
    with_host do |host, reaper|
      other = Hive::Attempts::ScopeReaper.unit_name("attempt-2")
      host.write_proc(SUPERVISOR, "/app.slice/#{other}.scope", "hive")
      assert_equal "unscoped", reaper.call.reap(term_grace_sec: 1).status

      host.write_proc(SUPERVISOR, "#{host.scope}/payload", "hive")
      assert_equal "unscoped", reaper.call.reap(term_grace_sec: 1).status
      assert_empty host.signals
    end
  end

  def test_missing_procfs_is_a_no_op
    with_host do |_host, reaper|
      assert_equal "unscoped", reaper.call(self_pid: 999).reap(term_grace_sec: 1).status
    end
  end

  def test_a_scope_holding_only_the_supervisor_is_clean
    with_host do |host, reaper|
      result = reaper.call.reap(term_grace_sec: 1)

      assert_equal "clean", result.status
      refute result.notable?
      assert_empty host.signals
    end
  end

  def test_leftovers_in_the_scope_and_its_sub_cgroups_are_terminated_and_recorded
    with_host do |host, reaper|
      host.add(200, comm: "conmon")
      host.add(201, comm: "pasta", cgroup: "/libpod-payload")

      result = reaper.call.reap(term_grace_sec: 1)

      assert_equal "reaped", result.status
      assert result.notable?
      assert_equal [ { "pid" => 200, "comm" => "conmon" }, { "pid" => 201, "comm" => "pasta" } ], result.reaped
      assert_empty result.survivors
      assert_equal [ [ "TERM", 200 ], [ "TERM", 201 ] ], host.signals
      refute_includes host.signals.map(&:last), SUPERVISOR
      line = result.journal_line
      assert line.start_with?("hive-attempt: scope_leftovers {")
      payload = JSON.parse(line.delete_prefix("hive-attempt: scope_leftovers "))
      assert_equal "#{Hive::Attempts::ScopeReaper.unit_name(ATTEMPT_ID)}.scope", payload.fetch("unit")
      assert_equal "reaped", payload.fetch("status")
      refute payload.key?("error")
    end
  end

  def test_a_leftover_ignoring_term_is_killed_after_the_grace
    with_host do |host, reaper|
      host.add(200, comm: "conmon", ignores: [ "TERM" ])

      result = reaper.call.reap(term_grace_sec: 0.2)

      assert_equal "reaped", result.status
      assert_equal [ 200 ], result.reaped.map { |entry| entry.fetch("pid") }
      assert_equal "KILL", host.signals.last.first
      assert_operator host.signals.count { |signal, _| signal == "TERM" }, :>=, 2
    end
  end

  def test_a_process_forked_during_termination_is_recorded_and_reaped
    with_host do |host, reaper|
      host.add(200, comm: "conmon")
      host.spawn_on_term(202, comm: "podman")

      result = reaper.call.reap(term_grace_sec: 1)

      assert_equal "reaped", result.status
      assert_equal [ 200, 202 ], result.reaped.map { |entry| entry.fetch("pid") }
    end
  end

  def test_an_unkillable_leftover_is_reported_incomplete_within_the_bound
    with_host do |host, reaper|
      host.add(200, comm: "stuck", ignores: %w[TERM KILL])
      host.add(201, comm: "conmon")

      result = reaper.call.reap(term_grace_sec: 0.2, kill_wait_sec: 0.2)

      assert_equal "incomplete", result.status
      assert result.notable?
      assert_equal [ { "pid" => 200, "comm" => "stuck" } ], result.survivors
      assert_equal [ { "pid" => 201, "comm" => "conmon" } ], result.reaped
    end
  end

  def test_a_listed_pid_that_now_lives_outside_the_scope_is_never_signalled
    with_host do |host, reaper|
      host.add(200, comm: "conmon")
      host.add(300, comm: "reused", ignores: %w[TERM KILL])
      host.place_outside(300, "/user.slice/app.slice/unrelated.service")

      result = reaper.call.reap(term_grace_sec: 0.1, kill_wait_sec: 0.1)

      refute_includes host.signals.map(&:last), 300
      assert_equal "incomplete", result.status
      assert_equal [ 300 ], result.survivors.map { |entry| entry.fetch("pid") }
    end
  end

  def test_signal_races_and_missing_proc_entries_are_contained
    with_host do |host, reaper|
      host.add(404, comm: nil, ignores: %w[TERM KILL])
      host.add(403, comm: "foreign", ignores: %w[TERM KILL])

      result = reaper.call.reap(term_grace_sec: 0.1, kill_wait_sec: 0.1)

      assert_equal "incomplete", result.status
      assert_equal [ { "pid" => 403, "comm" => "foreign" }, { "pid" => 404, "comm" => "" } ], result.survivors
    end
  end

  def test_an_unreadable_or_oversized_scope_is_reported_unavailable
    with_host do |host, reaper|
      stub_const(Hive::Attempts::ScopeReaper, :MAX_MEMBERS, 1) do
        host.add(200, comm: "a")
        host.add(201, comm: "b")

        result = reaper.call.reap(term_grace_sec: 1)

        assert_equal "unavailable", result.status
        assert result.notable?
        assert_match(/exceeds 1/, result.error)
        assert_includes result.journal_line, "\"error\":"
        assert_empty host.signals
      end
    end
  end

  def test_a_cgroup_file_that_vanished_reads_as_empty
    with_host do |_host, reaper|
      assert_equal [], reaper.call.send(:read_pids, "/nonexistent/cgroup.procs")
    end
  end

  private

  def with_host
    with_tmp_dir do |root|
      unit = "#{Hive::Attempts::ScopeReaper.unit_name(ATTEMPT_ID)}.scope"
      host = FakeHost.new(root, unit: unit)
      host.write_proc(SUPERVISOR, host.scope, "ruby")
      clock = [ 0.0 ]
      build = lambda do |self_pid: SUPERVISOR|
        Hive::Attempts::ScopeReaper.new(
          attempt_id: ATTEMPT_ID, proc_root: host.proc_root, cgroup_root: host.cgroup_root,
          self_pid: self_pid, signaller: host.signaller,
          monotonic: -> { clock.first }, sleeper: ->(seconds) { clock[0] += seconds }
        )
      end
      yield host, build
    end
  end

  def stub_const(owner, name, value)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end
end
