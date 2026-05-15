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
