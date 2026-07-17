require "hive/lock"
require "open3"

module Hive
  module ProcessKill
    TERM_GRACE_SECONDS = 2.0
    KILL_GRACE_SECONDS = 0.2
    POLL_INTERVAL_SECONDS = 0.05
    SYSTEM_PS_PATHS = [ "/bin/ps", "/usr/bin/ps" ].freeze

    Result = Struct.new(:pid, :killed, :skipped_reason, keyword_init: true)

    module_function

    # A PID of 0 means the current process group when passed to
    # Process.kill, and 1 is init. A malformed `.lock` or marker
    # leaking either through would target ourselves (or PID 1) instead
    # of an agent — refuse outright.
    def valid_target_pid?(pid)
      pid.is_a?(Integer) && pid > 1
    end

    def pid_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue ArgumentError, TypeError, Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Defense in depth for the PID-reuse guard: if the start-time lookup
    # raises (containerised /proc, missing ps, malformed lock metadata)
    # we return nil here and `pid_owned_by_recorded_start?` falls
    # through to "trust the recorded pid". Combined with the empty-live
    # short-circuit this means a hardened guard requires BOTH a
    # recorded start-time and a working start-time source.
    def process_start_time(pid)
      Hive::Lock.process_start_time(Integer(pid))
    rescue ArgumentError, TypeError
      nil
    end

    # Linux/macOS reuse PIDs aggressively under load. The recorded
    # start-time pinned at lock-acquire time is the discriminator: if
    # the live process boots with a different start-time, the original
    # agent has exited and the PID belongs to an unrelated process.
    def pid_owned_by_recorded_start?(pid, recorded_start_time)
      return true if recorded_start_time.to_s.empty?

      live = process_start_time(pid)
      return true if live.to_s.empty?

      recorded_start_time.to_s == live.to_s
    end

    def terminate_process(pid, recorded_start_time: nil, grace_seconds: TERM_GRACE_SECONDS)
      pid = Integer(pid)
      return Result.new(pid: pid, killed: false, skipped_reason: "invalid_pid") unless valid_target_pid?(pid)
      return Result.new(pid: pid, killed: false, skipped_reason: "not_alive") unless pid_alive?(pid)

      unless pid_owned_by_recorded_start?(pid, recorded_start_time)
        return Result.new(pid: pid, killed: false, skipped_reason: "pid_reuse_guard")
      end

      safe_kill("TERM", pid)
      wait_until_dead(pid, grace_seconds)
      if pid_alive?(pid)
        safe_kill("KILL", pid)
        wait_until_dead(pid, KILL_GRACE_SECONDS)
      end
      killed = !pid_alive?(pid)
      Result.new(pid: pid, killed: killed, skipped_reason: killed ? nil : "kill_failed")
    rescue ArgumentError, TypeError
      Result.new(pid: nil, killed: false, skipped_reason: "invalid_pid")
    rescue Errno::EPERM
      Result.new(pid: pid, killed: false, skipped_reason: "permission_denied")
    end

    def terminate_process_group(pid, recorded_start_time: nil, grace_seconds: TERM_GRACE_SECONDS)
      pid = Integer(pid)
      return Result.new(pid: pid, killed: false, skipped_reason: "invalid_pid") unless valid_target_pid?(pid)
      return Result.new(pid: pid, killed: false, skipped_reason: "not_alive") unless pid_alive?(pid)

      unless pid_owned_by_recorded_start?(pid, recorded_start_time)
        return Result.new(pid: pid, killed: false, skipped_reason: "pid_reuse_guard")
      end

      targets = process_tree_snapshot(pid)
      unless targets
        best_effort_terminate_root(pid, recorded_start_time, grace_seconds)
        return Result.new(pid: pid, killed: false, skipped_reason: "process_tree_unavailable")
      end
      if targets.empty?
        return Result.new(pid: pid, killed: false, skipped_reason: "not_alive") unless pid_alive?(pid)

        best_effort_terminate_root(pid, recorded_start_time, grace_seconds)
        return Result.new(pid: pid, killed: false, skipped_reason: "process_tree_unavailable")
      end

      targets = confirm_process_tree_snapshot(pid, targets)
      unless targets
        best_effort_terminate_root(pid, recorded_start_time, grace_seconds)
        return Result.new(pid: pid, killed: false, skipped_reason: "process_tree_unavailable")
      end
      if targets.empty?
        return Result.new(pid: pid, killed: false, skipped_reason: "not_alive") unless pid_alive?(pid)

        return Result.new(pid: pid, killed: false, skipped_reason: "pid_reuse_guard")
      end

      root_target = targets.find { |target| target.fetch(:pid) == pid }
      return Result.new(pid: pid, killed: false, skipped_reason: "pid_reuse_guard") unless root_target

      if !recorded_start_time.to_s.empty? && root_target[:start_time].to_s != recorded_start_time.to_s
        return Result.new(pid: pid, killed: false, skipped_reason: "pid_reuse_guard")
      end

      permission_denied = signal_captured_processes("TERM", targets)
      killed = wait_until_process_tree_dead(pid, targets, grace_seconds)
      unless killed
        kill_permission_denied = signal_captured_processes("KILL", targets, require_identity: true)
        permission_denied ||= kill_permission_denied
        killed = wait_until_process_tree_dead(pid, targets, KILL_GRACE_SECONDS)
      end
      reason = permission_denied ? "permission_denied" : "kill_failed"
      Result.new(pid: pid, killed: killed, skipped_reason: killed ? nil : reason)
    rescue ArgumentError, TypeError
      Result.new(pid: nil, killed: false, skipped_reason: "invalid_pid")
    rescue Errno::ESRCH
      Result.new(pid: pid, killed: false, skipped_reason: "not_alive")
    end

    # Agents may launch tool commands in their own process groups. Snapshot the
    # full descendant tree before signalling so those processes remain
    # addressable after their parent exits and init adopts them. Signal PIDs,
    # not process groups: a descendant can join a group containing unrelated
    # processes, and a PGID can be reused during TERM-to-KILL escalation.
    def process_tree_snapshot(pid)
      table = process_table
      return nil unless table
      return [] unless table.key?(pid)

      children = Hash.new { |hash, parent| hash[parent] = [] }
      table.each { |child_pid, row| children[row.fetch(:ppid)] << child_pid }

      pending = [ pid ]
      depths = { pid => 0 }
      cursor = 0
      while (parent = pending[cursor])
        cursor += 1
        children.fetch(parent, []).each do |child|
          depths[child] = depths.fetch(parent) + 1
          pending << child
        end
      end

      pending.filter_map do |target_pid|
        row = table[target_pid]
        next unless row && valid_target_pid?(target_pid)

        row.merge(pid: target_pid, start_time: process_start_time(target_pid), depth: depths.fetch(target_pid))
      end.sort_by { |target| [ -target.fetch(:depth), target.fetch(:pid) ] }
    end

    # `process_tree_snapshot` reads ancestry from one ps snapshot and process
    # identity immediately afterward. A PID can be recycled between those two
    # reads, producing a row with the old process's parent and the replacement
    # process's start time. Require a second full snapshot to reproduce the
    # same ancestry + identity tuple before TERM; mismatched descendants are
    # omitted and a mismatched root fails closed.
    def confirm_process_tree_snapshot(pid, targets)
      confirmation = process_tree_snapshot(pid)
      return nil unless confirmation

      by_pid = confirmation.to_h { |target| [ target.fetch(:pid), target ] }
      targets.select do |target|
        current = by_pid[target.fetch(:pid)]
        current && %i[ppid pgid start_time].all? { |key| current[key].to_s == target[key].to_s }
      end
    end

    def process_table
      ps_path = SYSTEM_PS_PATHS.find { |path| File.file?(path) && File.executable?(path) }
      return nil unless ps_path

      out, _err, status = Open3.capture3(ps_path, "-axo", "pid=,ppid=,pgid=")
      return nil unless status.success?

      rows = {}
      out.each_line do |line|
        fields = line.split
        next if fields.empty?
        return nil unless fields.length == 3

        pid, ppid, pgid = fields.map { |value| Integer(value, 10) }
        rows[pid] = { ppid: ppid, pgid: pgid }
      rescue ArgumentError
        return nil
      end
      rows
    rescue SystemCallError
      nil
    end

    def signal_captured_processes(signal, targets, require_identity: false)
      permission_denied = false
      targets.each do |target|
        next unless captured_process_current?(target, require_identity: require_identity)

        begin
          safe_kill(signal, target.fetch(:pid))
        rescue Errno::EPERM
          permission_denied = true
        end
      end
      permission_denied
    end

    def captured_process_current?(target, require_identity: false)
      expected = target[:start_time]
      return !require_identity && pid_alive?(target.fetch(:pid)) if expected.to_s.empty?

      live = process_start_time(target.fetch(:pid))
      !live.to_s.empty? && live.to_s == expected.to_s
    end

    def captured_process_alive?(target)
      expected = target[:start_time]
      return pid_alive?(target.fetch(:pid)) if expected.to_s.empty?

      live = process_start_time(target.fetch(:pid))
      return pid_alive?(target.fetch(:pid)) if live.to_s.empty?

      live.to_s == expected.to_s
    end

    def wait_until_process_tree_dead(pid, targets, seconds)
      deadline = Time.now + seconds
      while Time.now < deadline
        reap_if_child_exited(pid)
        return true unless targets.any? { |target| captured_process_alive?(target) }

        sleep POLL_INTERVAL_SECONDS
      end
      reap_if_child_exited(pid)
      targets.none? { |target| captured_process_alive?(target) }
    end

    def best_effort_terminate_root(pid, recorded_start_time, grace_seconds)
      expected = recorded_start_time
      expected = process_start_time(pid) if expected.to_s.empty?
      return if !expected.to_s.empty? && process_start_time(pid).to_s != expected.to_s

      begin
        safe_kill("TERM", pid)
      rescue Errno::EPERM
        return
      end
      wait_until_dead(pid, grace_seconds)
      return unless pid_alive?(pid)
      return if expected.to_s.empty?
      return unless process_start_time(pid).to_s == expected.to_s

      safe_kill("KILL", pid)
      wait_until_dead(pid, KILL_GRACE_SECONDS)
    rescue Errno::EPERM
      nil
    end

    def safe_kill(signal, target)
      Process.kill(signal, target)
    rescue Errno::ESRCH
      nil
    end

    def wait_until_dead(pid, seconds)
      deadline = Time.now + seconds
      while Time.now < deadline
        return true if reap_if_child_exited(pid)
        return true unless pid_alive?(pid)

        sleep POLL_INTERVAL_SECONDS
      end
      reap_if_child_exited(pid) || !pid_alive?(pid)
    end

    def reap_if_child_exited(pid)
      waited = Process.waitpid(pid, Process::WNOHANG)
      !waited.nil?
    rescue Errno::ECHILD
      false
    end
  end
end
