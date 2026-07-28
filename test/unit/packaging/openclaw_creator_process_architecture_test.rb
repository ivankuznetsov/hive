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
    containment_root.rb
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
    refute_includes sources.fetch("containment_owner.rb"), "enable_child_subreaper!"
    refute_includes sources.fetch("containment_root.rb"), "Open3.popen3"
    refute_includes sources.fetch("containment_root.rb"), "StreamCapture"
    refute_includes sources.fetch("containment_root.rb"), "NetworkCapture"
    assert_includes sources.fetch("containment_root.rb"), "warden.enable_child_subreaper!"
    assert_includes sources.fetch("containment_root.rb"), "Process::WUNTRACED"
    assert_includes sources.fetch("containment_root.rb"), "drain_child_domain"
    refute_includes sources.fetch("containment_session.rb"), "Open3.popen3"
    refute_includes sources.fetch("containment_session.rb"), "Thread.new"
    refute_match(
      /Process\.kill\(\s*["']KILL["']/,
      sources.fetch("containment_session.rb"),
      "ContainmentSession must not destroy its teardown authority"
    )
    refute_includes sources.fetch("containment_warden.rb"), "JSON."
    refute_includes sources.fetch("containment_warden.rb"), "Base64."
    assert_includes sources.fetch("containment_warden.rb"), "direct_pids"
    refute_includes sources.fetch("process_protocol.rb"), "Process.kill"
    refute_includes sources.fetch("process_protocol.rb"), "Process.fork"
    refute_includes sources.fetch("framed_json.rb"), '"teardown"'

    teardown_writers = sources.filter_map do |relative, source|
      relative if source.match?(/\["teardown"\]\s*=/)
    end
    assert_equal [ "containment_root.rb" ], teardown_writers
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
      assert_equal "independent_root",
                   result.dig("record", "teardown", "teardown_authority")
      assert_equal "not_claimed",
                   result.dig("record", "teardown", "root_loss_guarantee")
    end
  end

  def test_framed_json_normalizes_binary_text_before_encoding
    reader, writer = IO.pipe
    codec = HiveLiveAgentProof::OpenClawCreatorProof::FramedJson.new(
      max_bytes: 1_024
    )

    _stdout, stderr = capture_io do
      codec.write(
        writer,
        {
          "frame" => "failure",
          "detail" => "invalid-\xFF-text".b
        }
      )
    end
    writer.close
    payload = codec.read(
      reader,
      deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    )

    assert_empty stderr
    assert_equal "invalid-\uFFFD-text", payload.fetch("detail")
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def test_framed_json_stream_reader_is_incremental_and_rejects_partial_eof
    codec = HiveLiveAgentProof::OpenClawCreatorProof::FramedJson.new(
      max_bytes: 1_024
    )
    encoded = JSON.generate("frame" => "owner_ready", "worker_pid" => 123).b
    bytes = [ encoded.bytesize ].pack("N") + encoded
    reader, writer = IO.pipe
    stream = codec.stream_reader

    writer.write(bytes.byteslice(0, 3))
    assert_empty stream.read_available(reader)
    writer.write(bytes.byteslice(3..))
    assert_equal(
      [ { "frame" => "owner_ready", "worker_pid" => 123 } ],
      stream.read_available(reader)
    )
    writer.close
    assert_empty stream.read_available(reader)
    assert stream.eof?
    assert stream.finish!

    partial_reader, partial_writer = IO.pipe
    partial_stream = codec.stream_reader
    partial_writer.write([ 10 ].pack("N") + "{")
    partial_writer.close
    assert_empty partial_stream.read_available(partial_reader)
    assert partial_stream.eof?
    assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
      partial_stream.finish!
    end
  ensure
    reader&.close
    writer&.close unless writer&.closed?
    partial_reader&.close
    partial_writer&.close unless partial_writer&.closed?
  end

  def test_owner_death_before_ready_reaps_its_adopted_child
    with_tmp_dir do |dir|
      identity_path = File.join(dir, "pre-ready-child.json")
      owner = owner_that_dies(
        identity_path: identity_path,
        before_death: ->(_writer, _child) { }
      )

      error = run_faulted_owner(owner)

      assert_equal "containment_failed", error.reason
      assert_includes error.message, "before ready"
      assert_recorded_identity_gone(identity_path)
    end
  end

  def test_partial_owner_frame_reaps_its_adopted_child
    with_tmp_dir do |dir|
      identity_path = File.join(dir, "partial-frame-child.json")
      owner = owner_that_dies(
        identity_path: identity_path,
        before_death: lambda { |writer, _child|
          writer.write([ 128 ].pack("N"))
          writer.write("{")
          writer.flush
        }
      )

      error = run_faulted_owner(owner)

      assert_equal "containment_failed", error.reason
      assert_includes error.message, "truncated"
      assert_recorded_identity_gone(identity_path)
    end
  end

  def test_provisional_success_followed_by_owner_kill_is_rejected
    with_tmp_dir do |dir|
      identity_path = File.join(dir, "provisional-child.json")
      protocol = process_protocol
      payload = valid_worker_payload
      owner = owner_that_dies(
        identity_path: identity_path,
        before_death: lambda { |writer, child|
          protocol.write_owner_ready(writer, child)
          protocol.write_owner_outcome(
            writer,
            protocol.success_outcome(payload)
          )
        }
      )

      error = run_faulted_owner(owner, protocol: protocol)

      assert_equal "containment_failed", error.reason
      assert_includes error.message, "exited unsuccessfully"
      assert_recorded_identity_gone(identity_path)
    end
  end

  def test_subreaper_setup_failure_prevents_owner_creation
    with_tmp_dir do |dir|
      owner_started = File.join(dir, "owner-started")
      unavailable = HiveLiveAgentProof::OpenClawCreatorProof::Failure.new(
        phase: "process",
        reason: "containment_unavailable",
        detail: "synthetic subreaper refusal"
      )
      warden = Object.new
      warden.define_singleton_method(:enable_child_subreaper!) { raise unavailable }
      warden.define_singleton_method(:drain_child_domain) { [] }
      warden.define_singleton_method(:term_sent) { false }
      warden.define_singleton_method(:kill_sent) { false }
      owner_factory = lambda do |**_arguments|
        File.write(owner_started, "started")
        raise "owner must not be built"
      end

      error = run_faulted_owner(
        nil,
        owner_factory: owner_factory,
        warden_factory: ->(_pid) { warden }
      )

      assert_equal "containment_unavailable", error.reason
      assert_includes error.message, "synthetic subreaper refusal"
      refute_path_exists owner_started
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
    assert_nil @last_runner.containment_root_pid
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
    assert_nil @last_runner.containment_root_pid
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
    assert_nil @last_runner.containment_root_pid
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
    assert_nil @last_runner.containment_root_pid
    assert_nil @last_runner.owner_pid
    assert_nil @last_runner.worker_pid
  ensure
    session_class&.define_singleton_method(:start, original_start) if original_start
  end

  private

  def run_faulted_owner(owner, protocol: process_protocol,
                        owner_factory: nil, warden_factory: nil)
    budget = HiveLiveAgentProof::OpenClawCreatorProof::ProcessBudget.new(
      timeout: 0.2,
      term_grace: 0.05
    )
    owner_factory ||= ->(**_arguments) { owner }
    root_factory = lambda do |**arguments|
      HiveLiveAgentProof::OpenClawCreatorProof::ContainmentRoot.new(
        **arguments,
        owner_factory: owner_factory,
        warden_factory: warden_factory
      )
    end
    session =
      HiveLiveAgentProof::OpenClawCreatorProof::ContainmentSession.start(
        protocol: protocol,
        budget: budget,
        output_limit: 256,
        exact_secrets: [],
        secret_patterns: [],
        request: {},
        root_factory: root_factory
      )
    assert_raises(HiveLiveAgentProof::OpenClawCreatorProof::Failure) do
      session.result { |_ready| }
    end
  ensure
    session&.shutdown
    session&.close
  end

  def owner_that_dies(identity_path:, before_death:)
    Object.new.tap do |owner|
      owner.define_singleton_method(:run) do |writer, _request|
        child = Process.fork do
          writer.close
          Signal.trap("TERM", "IGNORE")
          loop { sleep 1 }
        end
        stat = File.binread("/proc/#{child}/stat")
        fields = stat[(stat.rindex(")") + 2)..].split
        File.write(
          identity_path,
          JSON.generate("pid" => child, "start_ticks" => fields.fetch(19))
        )
        before_death.call(writer, child)
        Process.kill("KILL", Process.pid)
      end
    end
  end

  def assert_recorded_identity_gone(path)
    identity = JSON.parse(File.binread(path))
    pid = identity.fetch("pid")
    expected = identity.fetch("start_ticks")
    refute process_identity_alive?(pid, expected),
           "original process identity #{pid}/#{expected} survived"
  ensure
    if identity && process_identity_alive?(identity["pid"], identity["start_ticks"])
      Process.kill("KILL", identity.fetch("pid"))
    end
  end

  def process_identity_alive?(pid, expected)
    stat = File.binread("/proc/#{Integer(pid)}/stat")
    fields = stat[(stat.rindex(")") + 2)..].split
    fields.fetch(19) == expected
  rescue Errno::ENOENT, Errno::ESRCH, ArgumentError, IndexError
    false
  end

  def process_protocol
    HiveLiveAgentProof::OpenClawCreatorProof::ProcessProtocol.new(
      output_limit: 256,
      detail_limit: HiveLiveAgentProof::OpenClawCreatorProof::DETAIL_LIMIT
    )
  end

  def valid_worker_payload
    empty_stream = {
      "sha256" => Digest::SHA256.hexdigest(""),
      "bytes" => 0,
      "retained_bytes" => 0,
      "truncated" => false
    }
    {
      "status_record" => { "exitstatus" => 0, "termsig" => nil },
      "stdout" => "",
      "stderr" => "",
      "secret_findings" => [],
      "record" => {
        "executable" => "ruby",
        "argv_sha256" => Digest::SHA256.hexdigest("[]"),
        "exit_status" => 0,
        "signal" => nil,
        "timed_out" => false,
        "interrupted" => false,
        "duration_ms" => 1,
        "stdout" => empty_stream,
        "stderr" => empty_stream,
        "network" => {
          "status" => "observed",
          "sample_count" => 0,
          "socket_count" => 0,
          "sockets" => []
        }
      },
      "worker_teardown" => {
        "term_sent" => false,
        "kill_sent" => false,
        "target_reaped" => true,
        "readers" => "complete",
        "writer" => "complete",
        "descendants" => "none"
      }
    }
  end

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
    ready =
      HiveLiveAgentProof::OpenClawCreatorProof::ProcessProtocol::Ready.new(
        owner_pid: 654_322,
        worker_pid: 654_323
      )
    Object.new.tap do |session|
      session.define_singleton_method(:pid) { 654_321 }
      session.define_singleton_method(:result) do |&callback|
        result.call { |_ignored| callback.call(ready) }
      end
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
