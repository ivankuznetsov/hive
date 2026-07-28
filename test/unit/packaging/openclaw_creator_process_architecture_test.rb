require "test_helper"
require "rbconfig"
require "timeout"
require_relative "../../../packaging/live_agent_skills/openclaw_creator_proof"

class OpenClawCreatorProcessArchitectureTest < Minitest::Test
  include HiveTestHelper

  SOURCE_ROOT = File.expand_path(
    "../../../packaging/live_agent_skills/openclaw_creator_proof",
    __dir__
  )
  PROCESS_FILES = %w[
    capture_worker.rb
    containment_owner.rb
    containment_session.rb
    containment_warden.rb
    framed_json.rb
    network_capture.rb
    process_budget.rb
    process_protocol.rb
    process_runner.rb
    process_tree.rb
    stream_capture.rb
  ].freeze

  def test_process_runner_is_a_thin_facade_over_bounded_collaborators
    sources = PROCESS_FILES.to_h do |relative|
      path = File.join(SOURCE_ROOT, relative)
      assert_path_exists path, "missing process collaborator #{relative}"
      [ relative, File.read(path) ]
    end

    assert_operator sources.fetch("process_runner.rb").lines.length, :<=, 180
    sources.each do |relative, source|
      assert_operator source.lines.length, :<=, 500, "#{relative} became a hotspot"
      refute_includes source, "Marshal", "#{relative} reintroduced unsafe IPC"
    end

    forbidden = [
      "Open3.popen3", "Process.fork", "Process.kill", "Process.wait",
      "Fiddle::", "Thread.new", "IO.select", "readpartial",
      "Base64.", "JSON.parse", '"/proc'
    ]
    forbidden.each do |token|
      refute_includes sources.fetch("process_runner.rb"), token,
                      "ProcessRunner owns #{token.inspect} instead of delegating"
    end

    refute_includes sources.fetch("capture_worker.rb"), "Process.fork"
    refute_includes sources.fetch("capture_worker.rb"), "prctl"
    refute_includes sources.fetch("capture_worker.rb"), "FramedJson"
    refute_includes sources.fetch("containment_owner.rb"), "Open3.popen3"
    refute_includes sources.fetch("containment_owner.rb"), "StreamCapture"
    refute_includes sources.fetch("containment_owner.rb"), "NetworkCapture"
    refute_includes sources.fetch("containment_session.rb"), "Open3.popen3"
    refute_includes sources.fetch("containment_session.rb"), "Thread.new"
    refute_includes sources.fetch("containment_warden.rb"), "JSON."
    refute_includes sources.fetch("containment_warden.rb"), "Base64."
    refute_includes sources.fetch("process_protocol.rb"), "Process.kill"
    refute_includes sources.fetch("process_protocol.rb"), "Process.fork"
    refute_includes sources.fetch("framed_json.rb"), '"teardown"'

    teardown_writers = sources.filter_map do |relative, source|
      relative if source.match?(/\["teardown"\]\s*=/)
    end
    assert_equal [ "containment_owner.rb" ], teardown_writers
  end

  def test_nonzero_target_remains_a_returned_process_result
    with_tmp_dir do |dir|
      script = File.join(dir, "nonzero")
      File.write(
        script,
        <<~RUBY
          #!#{RbConfig.ruby}
          STDOUT.binmode
          STDOUT.write("proof\\x00output")
          STDERR.write("expected failure")
          exit 7
        RUBY
      )
      FileUtils.chmod(0o700, script)
      runner = process_runner(timeout: 2)

      result = runner.call(environment: {}, argv: [ script ], chdir: dir)

      assert_equal 7, result.fetch("status").exitstatus
      assert_equal "proof\x00output".b, result.fetch("stdout")
      assert_equal "expected failure", result.fetch("stderr")
      assert_equal false, result.dig("record", "timed_out")
      assert_equal false, result.dig("record", "interrupted")
      assert_equal "passed", result.dig("record", "teardown", "status")
      assert_equal "none", result.dig("record", "teardown", "descendants")
    end
  end

  def test_network_capture_thread_that_cannot_stop_fails_closed
    capture_class = HiveLiveAgentProof::OpenClawCreatorProof::NetworkCapture
    original_start = capture_class.instance_method(:start)
    capture_class.define_method(:start) do
      @thread = Thread.new { sleep 30 }
      @thread.report_on_exception = false
    end

    with_tmp_dir do |dir|
      script = File.join(dir, "success")
      File.write(script, "#!#{RbConfig.ruby}\nexit 0\n")
      FileUtils.chmod(0o700, script)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = Timeout.timeout(6) do
        assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
          process_runner(timeout: 2).call(environment: {}, argv: [ script ], chdir: dir)
        end
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_equal "containment_failed", error.reason
      assert_operator elapsed, :<, 6
    end
  ensure
    capture_class&.define_method(:start, original_start) if original_start
  end

  def test_network_capture_thread_failure_is_observed
    failing_capture = Class.new(
      HiveLiveAgentProof::OpenClawCreatorProof::NetworkCapture
    ) do
      def start
        @thread = Thread.new { raise "sampler exploded" }
        @thread.report_on_exception = false
      end
    end
    worker_factory = lambda do |**arguments|
      HiveLiveAgentProof::OpenClawCreatorProof::CaptureWorker.new(
        **arguments,
        network_capture_factory: ->(pid) { failing_capture.new(pid) }
      )
    end

    error = run_success_script(worker_factory: worker_factory)

    assert_equal "containment_failed", error.reason
    assert_includes error.message, "network capture thread failed"
    assert_includes error.message, "sampler exploded"
  end

  def test_stream_reader_thread_failure_is_observed
    pattern = Object.new
    pattern.define_singleton_method(:match?) { |_text| raise "scanner exploded" }
    worker_factory = lambda do |**arguments|
      HiveLiveAgentProof::OpenClawCreatorProof::CaptureWorker.new(
        **arguments.merge(secret_patterns: [ pattern ])
      )
    end

    error = run_success_script(worker_factory: worker_factory, stdout: "proof")

    assert_equal "containment_failed", error.reason
    assert_includes error.message, "stream reader thread failed"
    assert_includes error.message, "scanner exploded"
  end

  def test_stdin_writer_thread_failure_is_observed
    stdin_data = Object.new
    stdin_data.define_singleton_method(:to_s) { raise "writer exploded" }

    error = run_success_script(stdin_data: stdin_data)

    assert_equal "containment_failed", error.reason
    assert_includes error.message, "stdin writer thread failed"
    assert_includes error.message, "writer exploded"
  end

  def test_timeout_validation_boundary_remains_stable
    assert_raises(ArgumentError) { process_runner(timeout: 0) }
    error = assert_raises(
      HiveLiveAgentProof::OpenClawCreatorProof::Failure
    ) do
      process_runner(timeout: 2).call(
        environment: {},
        argv: [ "/unused" ],
        chdir: Dir.pwd,
        timeout: 0
      )
    end

    assert_equal "containment_failed", error.reason
    assert_includes error.message, "timeout must be positive"
  end

  def test_session_close_and_pid_reset_survive_shutdown_failure
    original = HiveLiveAgentProof::OpenClawCreatorProof::Failure.new(
      phase: "process",
      reason: "original_failure",
      detail: "preserve this failure"
    )
    closed = false
    session = fake_session(
      result: ->(&ready) { ready.call(654_322); raise original },
      shutdown: -> { raise Errno::EIO, "shutdown exploded" },
      close: -> { closed = true }
    )

    error = with_containment_session(session) do
      assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
        process_runner(timeout: 2).call(
          environment: {},
          argv: [ "/unused" ],
          chdir: Dir.pwd
        )
      end
    end

    assert_same original, error
    assert closed
    assert_nil @last_runner.owner_pid
    assert_nil @last_runner.worker_pid
  end

  def test_shutdown_failure_after_success_is_typed_and_still_closes
    closed = false
    session = fake_session(
      result: ->(&ready) { ready.call(654_324); { "result" => "complete" } },
      shutdown: -> { raise Errno::EIO, "shutdown exploded" },
      close: -> { closed = true }
    )

    error = with_containment_session(session) do
      assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
        process_runner(timeout: 2).call(
          environment: {},
          argv: [ "/unused" ],
          chdir: Dir.pwd
        )
      end
    end

    assert_equal "containment_failed", error.reason
    assert_includes error.message, "shutdown exploded"
    assert closed
    assert_nil @last_runner.owner_pid
    assert_nil @last_runner.worker_pid
  end

  def test_parent_system_call_errors_are_typed_and_cleanup_is_unconditional
    closed = false
    session = fake_session(
      result: ->(&ready) { ready.call(654_323); raise Errno::EIO, "wait exploded" },
      shutdown: -> { },
      close: -> { closed = true }
    )

    error = with_containment_session(session) do
      assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
        process_runner(timeout: 2).call(
          environment: {},
          argv: [ "/unused" ],
          chdir: Dir.pwd
        )
      end
    end

    assert_equal "containment_failed", error.reason
    assert_includes error.message, "wait exploded"
    assert closed
    assert_nil @last_runner.owner_pid
    assert_nil @last_runner.worker_pid
  end

  def test_pipe_or_fork_system_call_errors_are_typed
    session_class =
      HiveLiveAgentProof::OpenClawCreatorProof::ContainmentSession
    original_start = session_class.method(:start)
    session_class.define_singleton_method(:start) do |**_arguments|
      raise Errno::EMFILE, "fork resources exhausted"
    end

    error = assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
      process_runner(timeout: 2).call(
        environment: {},
        argv: [ "/unused" ],
        chdir: Dir.pwd
      )
    end

    assert_equal "containment_failed", error.reason
    assert_includes error.message, "fork resources exhausted"
    assert_nil @last_runner.owner_pid
    assert_nil @last_runner.worker_pid
  ensure
    session_class&.define_singleton_method(:start, original_start) if original_start
  end

  private

  def process_runner(timeout:, worker_factory: nil)
    @last_runner = HiveLiveAgentProof::OpenClawCreatorProof::ProcessRunner.new(
      timeout: timeout,
      term_grace: 0.1,
      output_limit: 256,
      exact_secrets: [],
      worker_factory: worker_factory
    )
  end

  def run_success_script(worker_factory: nil, stdin_data: nil, stdout: nil)
    with_tmp_dir do |dir|
      script = File.join(dir, "success")
      File.write(
        script,
        "#!#{RbConfig.ruby}\nSTDOUT.write(#{stdout.to_s.dump})\nexit 0\n"
      )
      FileUtils.chmod(0o700, script)

      return assert_raises(
        HiveLiveAgentProof::OpenClawCreatorProof::Failure
      ) do
        process_runner(timeout: 2, worker_factory: worker_factory).call(
          environment: {},
          argv: [ script ],
          chdir: dir,
          stdin_data: stdin_data
        )
      end
    end
  end

  def fake_session(result:, shutdown:, close:)
    Object.new.tap do |session|
      session.define_singleton_method(:pid) { 654_321 }
      session.define_singleton_method(:result, &result)
      session.define_singleton_method(:shutdown, &shutdown)
      session.define_singleton_method(:close, &close)
    end
  end

  def with_containment_session(session)
    session_class =
      HiveLiveAgentProof::OpenClawCreatorProof::ContainmentSession
    original_start = session_class.method(:start)
    session_class.define_singleton_method(:start) { |**_arguments| session }
    yield
  ensure
    session_class&.define_singleton_method(:start, original_start) if original_start
  end
end
