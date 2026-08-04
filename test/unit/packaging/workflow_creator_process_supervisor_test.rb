require "test_helper"
require "fileutils"
require "rbconfig"
require_relative "../../../packaging/live_agent_skills/workflow_creator_process_supervisor"

class WorkflowCreatorProcessSupervisorTest < Minitest::Test
  Supervisor = HiveLiveAgentProof::WorkflowCreator::ProcessSupervisor
  RUBY = File.realpath(RbConfig.ruby)

  def setup
    skip "Linux process custody is required" unless RUBY_PLATFORM.include?("linux")
  end

  def test_has_one_closed_creator_label_for_each_command_and_root
    assert_equal %w[
      candidate-version candidate-workflow-list candidate-workflow-new candidate-workflow-validate
      candidate-workflow-commit candidate-task-create candidate-task-run candidate-task-retry
      candidate-operational-status outer-workflow-creator outer-authorized-work
    ], Supervisor::LABELS
    assert Supervisor::LABELS.frozen?
  end

  def test_zero_launches_is_not_started_and_partial_launches_cannot_pass
    Dir.mktmpdir("creator-supervisor") do |dir|
      supervisor = build_supervisor
      assert_equal "not_started", supervisor.teardown.fetch("status")

      receipt = run_command(supervisor, dir, position: 1)

      assert_equal "passed", receipt.dig("teardown", "status")
      assert_equal "failed", supervisor.teardown.fetch("status")
      assert_raises(Supervisor::Error) { run_command(supervisor, dir, position: 1) }
      assert_raises(Supervisor::Error) { run_command(supervisor, dir, position: 0) }
    end
  end

  def test_all_closed_labels_produce_one_complete_teardown_row
    Dir.mktmpdir("creator-supervisor") do |dir|
      supervisor = build_supervisor
      1.upto(9) { |position| run_command(supervisor, dir, position: position) }
      supervisor.run_outer_workflow_creator(**launch_options(dir))
      supervisor.run_outer_authorized_work(**launch_options(dir))

      teardown = supervisor.teardown
      assert_equal "passed", teardown.fetch("status")
      assert_equal Supervisor::LABELS, teardown.fetch("receipt_labels")
      assert_equal 11, supervisor.receipts.length
      assert supervisor.receipts.all? { |row| row.dig("teardown", "owner_complete") }
    end
  end

  def test_containment_precedes_sensitive_input_and_receipts_are_not_inherited
    secret = "supervisor-private-secret"
    Dir.mktmpdir("creator-supervisor") do |dir|
      supervisor = build_supervisor(exact_secrets: [ secret ])
      code = <<~'RUBY'
        inherited = (3..64).count do |fd|
          IO.for_fd(fd, autoclose: false).write("forged")
          true
        rescue StandardError
          false
        end
        STDOUT.write(STDIN.read)
        STDERR.write("fds=#{inherited}")
      RUBY
      receipt = supervisor.run_command(
        position: 1, executable: RUBY, argv: [ "-e", code ], environment: {}, cwd: dir,
        stdin_data: secret
      )

      assert receipt.fetch("containment_established")
      assert_equal "failed", receipt.dig("capture", "secret_scan", "status")
      assert_equal "[REDACTED]", receipt.dig("capture", "tails", "stdout")
      assert_equal "fds=0", receipt.dig("capture", "tails", "stderr")
    end
  end

  def test_timeout_escalates_term_to_kill_and_reaps_the_root
    Dir.mktmpdir("creator-supervisor") do |dir|
      supervisor = build_supervisor(timeout: 0.2, term_grace: 0.03, kill_grace: 0.2)
      receipt = supervisor.run_command(
        position: 1, executable: RUBY,
        argv: [ "-e", "trap('TERM') {}; sleep 30" ], environment: {}, cwd: dir
      )

      assert receipt.fetch("timed_out")
      assert receipt.dig("teardown", "term_sent")
      assert receipt.dig("teardown", "kill_sent")
      assert receipt.dig("teardown", "reaped")
      assert_equal "none", receipt.dig("teardown", "descendants")
    end
  end

  def test_continuous_output_cannot_starve_timeout_or_reaping
    pid = nil
    Dir.mktmpdir("creator-supervisor-output") do |dir|
      pid_file = File.join(dir, "writer.pid")
      code = <<~RUBY
        File.write(#{pid_file.dump}, Process.pid)
        trap("TERM") {}
        chunk = "x" * 8_192
        loop { STDOUT.write(chunk); STDOUT.flush }
      RUBY
      supervisor = build_supervisor(timeout: 0.1, term_grace: 0.03, kill_grace: 0.2,
                                    output_limit: 4_096)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      receipt = supervisor.run_command(
        position: 1, executable: RUBY, argv: [ "-e", code ], environment: {}, cwd: dir
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      pid = Integer(File.read(pid_file))

      assert receipt.fetch("timed_out")
      assert receipt.dig("capture", "stdout_truncated")
      assert_equal "passed", receipt.dig("teardown", "status")
      assert_operator elapsed, :<, 2
      refute process_alive?(pid)
    end
  ensure
    Process.kill("KILL", pid) if pid && process_alive?(pid)
  end

  def test_detached_descendant_is_discovered_killed_and_reaped_after_root_exit
    detached_pid = nil
    Dir.mktmpdir("creator-supervisor") do |dir|
      pid_file = File.join(dir, "detached.pid")
      child = "Process.setsid; trap('TERM') {}; File.write(ARGV.fetch(0), Process.pid); sleep 30"
      root = <<~RUBY
        Process.spawn(#{RUBY.dump}, "-e", #{child.dump}, #{pid_file.dump}, out: File::NULL, err: File::NULL)
        sleep 0.01 until File.exist?(#{pid_file.dump})
      RUBY
      supervisor = build_supervisor
      receipt = supervisor.run_command(
        position: 1, executable: RUBY, argv: [ "-e", root ], environment: {}, cwd: dir
      )
      detached_pid = Integer(File.read(pid_file))

      assert receipt.dig("teardown", "kill_sent")
      refute process_alive?(detached_pid)
      assert_equal "passed", receipt.dig("teardown", "status")
    end
  ensure
    Process.kill("KILL", detached_pid) if detached_pid && process_alive?(detached_pid)
  end

  def test_capture_failure_still_reaps_a_detached_term_ignoring_descendant
    detached_pid = nil
    Dir.mktmpdir("creator-supervisor") do |dir|
      pid_file = File.join(dir, "failure-detached.pid")
      child = "Process.setsid; trap('TERM') {}; File.write(ARGV.fetch(0), Process.pid); sleep 30"
      root = <<~RUBY
        Process.spawn(#{RUBY.dump}, "-e", #{child.dump}, #{pid_file.dump}, out: File::NULL, err: File::NULL)
        sleep 30
      RUBY
      failing_supervisor = Class.new(Supervisor) do
        define_method(:initialize) do |fault_file:, **options|
          @fault_file = fault_file
          super(**options)
        end

        private

        def drain(...)
          unless @faulted
            sleep 0.01 until File.exist?(@fault_file)
            @faulted = true
            raise IOError, "forced capture failure"
          end
          super
        end
      end.new(
        fault_file: pid_file, correlation_id: "creator-run", timeout: 1,
        term_grace: 0.05, kill_grace: 0.2
      )

      assert_raises(Supervisor::Error) do
        failing_supervisor.run_command(
          position: 1, executable: RUBY, argv: [ "-e", root ], environment: {}, cwd: dir
        )
      end
      detached_pid = Integer(File.read(pid_file))
      refute process_alive?(detached_pid)
      assert_equal "failed", failing_supervisor.teardown.fetch("status")
    end
  ensure
    Process.kill("KILL", detached_pid) if detached_pid && process_alive?(detached_pid)
  end

  def test_caller_loss_reaps_a_detached_term_ignoring_descendant
    caller_pid = detached_pid = nil
    Dir.mktmpdir("creator-caller-loss") do |dir|
      pid_file = File.join(dir, "caller-loss-detached.pid")
      child = "Process.setsid; trap('TERM') {}; File.write(ARGV.fetch(0), Process.pid); sleep 30"
      root = <<~RUBY
        Process.spawn(#{RUBY.dump}, "-e", #{child.dump}, #{pid_file.dump}, out: File::NULL, err: File::NULL)
        sleep 30
      RUBY
      caller_pid = Process.fork do
        build_supervisor(timeout: 30).run_command(
          position: 1, executable: RUBY, argv: [ "-e", root ], environment: {}, cwd: dir
        )
      end
      wait_until { File.exist?(pid_file) }
      detached_pid = Integer(File.read(pid_file))

      Process.kill("KILL", caller_pid)
      Process.waitpid(caller_pid)
      caller_pid = nil

      wait_until { !process_alive?(detached_pid) }
      refute process_alive?(detached_pid)
    end
  ensure
    Process.kill("KILL", caller_pid) if caller_pid && process_alive?(caller_pid)
    Process.waitpid(caller_pid) if caller_pid
    Process.kill("KILL", detached_pid) if detached_pid && process_alive?(detached_pid)
  end

  def test_proof_workspace_refuses_preexisting_paths_and_removes_only_its_identity
    Dir.mktmpdir("creator-cleanup") do |dir|
      supervisor = build_supervisor
      %w[file directory symlink].each do |kind|
        path = File.join(dir, kind)
        kind == "file" ? File.write(path, "keep") : Dir.mkdir(path)
        if kind == "symlink"
          Dir.rmdir(path)
          File.symlink("file", path)
        end
        assert_raises(Supervisor::Error) { supervisor.create_proof_workspace(path) }
        assert File.exist?(path) || File.symlink?(path)
      end

      owned = File.join(dir, "owned")
      row = supervisor.create_proof_workspace(owned)
      assert_equal true, row.fetch("created_by_run")
      cleanup = supervisor.cleanup_proof_workspace
      assert cleanup.values_at("identity_matched", "removed").all?
      refute File.exist?(owned)
    end
  end

  def test_replacement_after_workspace_creation_fails_closed_without_deleting_it
    Dir.mktmpdir("creator-cleanup") do |dir|
      supervisor = build_supervisor
      owned = File.join(dir, "owned")
      original = File.join(dir, "original")
      supervisor.create_proof_workspace(owned)
      File.rename(owned, original)
      Dir.mkdir(owned)

      row = supervisor.cleanup_proof_workspace

      assert_equal false, row.fetch("identity_matched")
      assert_equal false, row.fetch("removed")
      assert Dir.exist?(owned)
      refute row.values_at("identity_matched", "removed").all?
    end
  end

  def test_non_linux_platform_fails_closed
    error = assert_raises(Supervisor::Error) do
      Supervisor.new(correlation_id: "creator-run", platform: "darwin")
    end
    assert_equal "workflow-creator process custody requires Linux", error.message
  end

  private

  def build_supervisor(**options)
    Supervisor.new(
      correlation_id: "creator-run", timeout: 1, term_grace: 0.05, kill_grace: 0.2,
      **options
    )
  end

  def launch_options(dir)
    { executable: RUBY, argv: [ "-e", "exit 0" ], environment: {}, cwd: dir }
  end

  def run_command(supervisor, dir, position:)
    supervisor.run_command(position: position, **launch_options(dir))
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition did not become true" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end
end
