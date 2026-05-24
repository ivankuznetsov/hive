require "test_helper"
require "hive/bot/child_supervisor"

class HiveBotChildSupervisorTest < Minitest::Test
  include HiveTestHelper

  def logger
    @logger ||= StubLogger.new
  end

  def script(dir, body)
    path = File.join(dir, "child.rb")
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  def supervisor(log_path:)
    Hive::Bot::ChildSupervisor.new(
      logger: logger,
      log_dir_for_task: ->(_project, _slug) { log_path }
    )
  end

  def test_dispatch_and_reap_success_with_json_envelope
    with_tmp_dir do |dir|
      log_path = File.join(dir, "child.log")
      child = script(dir, <<~RUBY)
        #!/usr/bin/env ruby
        puts '{"schema":"hive-stage-action","ok":true,"marker_after":"complete"}'
        exit 0
      RUBY
      sup = supervisor(log_path: log_path)

      pid = sup.dispatch(command_argv: [ RbConfig.ruby, child ],
                         cwd: dir, chat_id: 123, update_id: 10,
                         project: "hive", slug: "slug")
      exits = wait_for_exit(sup)

      assert_equal pid, exits.first.pid
      assert_equal 0, exits.first.exit_code
      assert_equal true, exits.first.json_envelope["ok"]
      assert_equal 0, sup.in_flight_count
      assert_equal :command_completed, logger.events.last.first
    end
  end

  def test_malformed_json_yields_nil_envelope
    with_tmp_dir do |dir|
      log_path = File.join(dir, "child.log")
      child = script(dir, "#!/usr/bin/env ruby\nputs 'not json'\n")
      sup = supervisor(log_path: log_path)

      sup.dispatch(command_argv: [ RbConfig.ruby, child ],
                   cwd: dir, chat_id: 123, update_id: 10,
                   project: "hive", slug: "slug")
      exit = wait_for_exit(sup).first

      assert_nil exit.json_envelope
    end
  end

  def test_wrong_stage_exit_is_preserved_for_caller_mapping
    with_tmp_dir do |dir|
      log_path = File.join(dir, "child.log")
      child = script(dir, <<~RUBY)
        #!/usr/bin/env ruby
        puts '{"schema":"hive-stage-action","ok":false,"error_kind":"wrong_stage"}'
        exit 4
      RUBY
      sup = supervisor(log_path: log_path)

      sup.dispatch(command_argv: [ RbConfig.ruby, child ],
                   cwd: dir, chat_id: 123, update_id: 10,
                   project: "hive", slug: "slug")
      exit = wait_for_exit(sup).first

      assert_equal Hive::ExitCodes::WRONG_STAGE, exit.exit_code
      assert_equal "wrong_stage", exit.json_envelope["error_kind"]
    end
  end

  def test_dry_run_reaps_synthetic_child
    sup = Hive::Bot::ChildSupervisor.new(logger: logger, dry_run: true)
    pid = sup.dispatch(command_argv: [ "hive", "plan", "slug" ],
                       cwd: Dir.pwd, chat_id: 123, update_id: 10,
                       project: "hive", slug: "slug")

    assert_operator pid, :<, 0
    exits = sup.reap_dry_run
    assert_equal 1, exits.size
    assert_equal 0, exits.first.exit_code
  end

  def test_terminate_all_clears_running_child
    with_tmp_dir do |dir|
      log_path = File.join(dir, "child.log")
      child = script(dir, "#!/usr/bin/env ruby\nsleep 10\n")
      sup = supervisor(log_path: log_path)
      sup.dispatch(command_argv: [ RbConfig.ruby, child ],
                   cwd: dir, chat_id: 123, update_id: 10,
                   project: "hive", slug: "slug")

      sup.terminate_all(grace_sec: 0)

      assert_equal 0, sup.in_flight_count
    end
  end

  def test_terminate_all_escalates_to_sigkill_for_sigterm_ignoring_child
    with_tmp_dir do |dir|
      log_path = File.join(dir, "child.log")
      child = script(dir, <<~RUBY)
        #!/usr/bin/env ruby
        Signal.trap("TERM") { }
        sleep 30
      RUBY
      sup = supervisor(log_path: log_path)
      sup.dispatch(command_argv: [ RbConfig.ruby, child ],
                   cwd: dir, chat_id: 123, update_id: 10,
                   project: "hive", slug: "slug")

      sup.terminate_all(grace_sec: 0)

      assert_equal 0, sup.in_flight_count,
                   "TERM-ignoring child must be reaped via SIGKILL escalation"
    end
  end

  def test_reap_all_records_exit_when_pid_is_no_longer_a_child
    sup = supervisor(log_path: nil)
    entry = sup.send(:entry, project: "hive", slug: "orphan", command_argv: [ "hive", "status" ],
                     chat_id: 123, update_id: 10, started_at: Time.now, log_path: nil, dry_run: false)
    sup.instance_variable_get(:@running)[987_654_321] = entry

    exits = sup.reap_all

    assert_equal 1, exits.size
    assert_equal 987_654_321, exits.first.pid
    assert_nil exits.first.exit_code
    assert_equal exits.first, sup.completed_exit(987_654_321)
  end

  def test_in_flight_pids_returns_snapshot_of_running_children
    sup = Hive::Bot::ChildSupervisor.new(logger: logger, dry_run: true)
    first = sup.dispatch(command_argv: [ "hive", "plan", "alpha" ], cwd: Dir.pwd, chat_id: 1, update_id: 1)
    second = sup.dispatch(command_argv: [ "hive", "review", "beta" ], cwd: Dir.pwd, chat_id: 1, update_id: 2)

    assert_equal [ first, second ].sort, sup.in_flight_pids.sort
  end

  def test_derive_slug_handles_known_verbs_unknown_commands_and_missing_candidates
    sup = Hive::Bot::ChildSupervisor.new(logger: logger, hive_bin: "/opt/hive")

    assert_equal "task-1", sup.send(:derive_slug, [ "/opt/hive", "plan", "task-1" ])
    assert_nil sup.send(:derive_slug, [ "/opt/hive", "status", "--json" ])
    assert_nil sup.send(:derive_slug, [ "/opt/hive", "plan", "--json" ])
    assert_equal "unknown", sup.send(:derive_slug, [ "--json" ])
  end

  def test_log_path_for_uses_tmpdir_when_project_has_no_hive_state
    sup = Hive::Bot::ChildSupervisor.new(logger: logger)

    path = sup.send(:log_path_for, cwd: "/tmp/no-such-hive-project", project: "proj", slug: "slug")

    assert_includes path, File.join(Dir.tmpdir, "hive-bot-logs", "proj", "slug")
    assert_match(/bot-dispatch-.*\.log\z/, path)
  end

  def test_parse_envelope_logs_empty_no_candidate_and_malformed_failures
    with_tmp_dir do |dir|
      sup = supervisor(log_path: File.join(dir, "unused.log"))

      empty = File.join(dir, "empty.log")
      File.write(empty, "")
      assert_nil sup.send(:parse_envelope, empty)
      assert_equal "empty_tail", logger.events.last.last.fetch(:reason)

      no_json = File.join(dir, "no-json.log")
      File.write(no_json, "plain output\n")
      assert_nil sup.send(:parse_envelope, no_json)
      assert_equal "no_json_candidate", logger.events.last.last.fetch(:reason)

      malformed = File.join(dir, "malformed.log")
      File.write(malformed, "{not-json}\n")
      assert_nil sup.send(:parse_envelope, malformed)
      assert_equal "malformed_json", logger.events.last.last.fetch(:reason)
    end
  end

  def test_parse_envelope_uses_last_valid_json_candidate
    with_tmp_dir do |dir|
      log_path = File.join(dir, "child.log")
      File.write(log_path, <<~LOG)
        noisy line
        {not-json}
        {"schema":"hive-run","ok":true}
      LOG
      sup = supervisor(log_path: log_path)

      envelope = sup.send(:parse_envelope, log_path)

      assert_equal "hive-run", envelope.fetch("schema")
      assert_equal true, envelope.fetch("ok")
    end
  end

  def test_read_tail_drops_partial_first_line_when_starting_mid_file
    with_tmp_dir do |dir|
      log_path = File.join(dir, "long.log")
      File.write(log_path, "first line\nsecond line\nthird line\n")
      sup = supervisor(log_path: log_path)

      tail = sup.send(:read_tail, log_path, 18)

      refute_includes tail, "first line"
      assert_includes tail, "third line"
    end
  end

  def test_read_tail_missing_file_returns_nil
    sup = supervisor(log_path: nil)

    assert_nil sup.send(:read_tail, "/tmp/hive-missing-log-#{Process.pid}-#{rand(1000)}", 1024)
  end

  def test_reap_all_tolerates_concurrent_running_entry_removal
    sup = supervisor(log_path: nil)
    running = sup.instance_variable_get(:@running)
    running[111] = sup.send(:entry, project: "hive", slug: "one", command_argv: [ "hive", "status" ],
                            chat_id: 1, update_id: 1, started_at: Time.now, log_path: nil, dry_run: false)
    running[222] = sup.send(:entry, project: "hive", slug: "two", command_argv: [ "hive", "status" ],
                            chat_id: 1, update_id: 2, started_at: Time.now, log_path: nil, dry_run: false)
    status = Struct.new(:exitstatus).new(0)

    with_replaced_singleton_method(Process, :wait2, lambda { |pid, _flags|
      running.delete(pid)
      raise Errno::ECHILD if pid == 111

      [ pid, status ]
    }) do
      assert_empty sup.reap_all
    end

    assert_empty sup.in_flight_pids
  end

  def test_terminate_all_waits_for_reap_before_escalating
    sup = supervisor(log_path: nil)
    running = sup.instance_variable_get(:@running)
    running[456] = sup.send(:entry, project: "hive", slug: "task", command_argv: [ "hive", "status" ],
                            chat_id: 1, update_id: 1, started_at: Time.now, log_path: nil, dry_run: false)
    kills = []
    reaps = 0
    sup.define_singleton_method(:collect_pgids) { [ 456 ] }
    sup.define_singleton_method(:safe_kill) { |signal, target| kills << [ signal, target ] }
    sup.define_singleton_method(:sleep) { |_seconds| nil }
    sup.define_singleton_method(:reap_all) do |now: Time.now|
      reaps += 1
      running.delete(456)
      []
    end

    sup.terminate_all(grace_sec: 1)

    assert_equal [ [ :TERM, -456 ] ], kills
    assert_operator reaps, :>=, 1
    assert_empty sup.in_flight_pids
  end

  def test_terminate_all_prunes_only_confirmed_gone_stale_pids
    sup = supervisor(log_path: nil)
    running = sup.instance_variable_get(:@running)
    [ 11, 22, 33 ].each do |pid|
      running[pid] = sup.send(:entry, project: "hive", slug: "task", command_argv: [ "hive", "status" ],
                              chat_id: 1, update_id: pid, started_at: Time.now, log_path: nil, dry_run: false)
    end
    sup.define_singleton_method(:collect_pgids) { [] }
    sup.define_singleton_method(:reap_all) { |now: Time.now| [] }
    sup.define_singleton_method(:sleep) { |_seconds| nil }

    with_replaced_singleton_method(Process, :getpgid, ->(_pid) { raise Errno::ESRCH }) do
      with_replaced_singleton_method(Process, :kill, lambda { |signal, pid|
        raise "unexpected signal #{signal}" unless signal.zero?

        case pid
        when 11 then 1
        when 22 then raise Errno::ESRCH
        when 33 then raise Errno::EPERM
        end
      }) do
        sup.terminate_all(grace_sec: 0)
      end
    end

    assert_equal [ 11, 33 ], sup.in_flight_pids.sort
  end

  def test_log_path_for_uses_project_hive_state_when_present
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      sup = Hive::Bot::ChildSupervisor.new(logger: logger)

      path = sup.send(:log_path_for, cwd: dir, project: "proj", slug: "slug")

      assert_includes path, File.join(dir, ".hive-state", "logs", "slug")
      assert_match(/bot-dispatch-.*\.log\z/, path)
    end
  end

  def test_read_tail_logs_read_failures
    sup = supervisor(log_path: nil)

    with_replaced_singleton_method(File, :open, ->(_path, _mode) { raise IOError, "blocked" }) do
      assert_nil sup.send(:read_tail, "/tmp/blocked.log", 1024)
    end

    event, attrs = logger.events.last
    assert_equal :envelope_parse_failure, event
    assert_equal "read_tail_failed", attrs.fetch(:reason)
    assert_equal "IOError", attrs.fetch(:error_class)
  end

  def test_collect_pgids_skips_missing_processes
    sup = supervisor(log_path: nil)
    sup.instance_variable_get(:@running)[777] = sup.send(
      :entry,
      project: "hive", slug: "task", command_argv: [ "hive", "status" ],
      chat_id: 1, update_id: 1, started_at: Time.now, log_path: nil, dry_run: false
    )

    with_replaced_singleton_method(Process, :getpgid, ->(_pid) { raise Errno::ESRCH }) do
      assert_empty sup.send(:collect_pgids)
    end
  end

  def test_safe_kill_ignores_missing_or_forbidden_targets
    sup = supervisor(log_path: nil)

    with_replaced_singleton_method(Process, :kill, ->(_signal, _target) { raise Errno::EPERM }) do
      assert_nil sup.send(:safe_kill, :TERM, -123)
    end

    with_replaced_singleton_method(Process, :kill, ->(_signal, _target) { raise Errno::ESRCH }) do
      assert_nil sup.send(:safe_kill, :TERM, -456)
    end
  end

  def wait_for_exit(sup)
    deadline = Time.now + 5
    loop do
      exits = sup.reap_all
      return exits unless exits.empty?

      raise "child did not exit" if Time.now > deadline

      sleep 0.05
    end
  end


  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end
end
