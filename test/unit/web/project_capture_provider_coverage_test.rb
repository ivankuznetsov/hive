require "test_helper"
require "hive/web/project_capture_provider"

class WebProjectCaptureProviderCoverageTest < Minitest::Test
  include HiveTestHelper

  FakeStatus = Data.define(:success_value, :signaled_value, :exitstatus, :termsig) do
    def success? = success_value
    def signaled? = signaled_value
  end

  def test_call_and_executable_validation_errors_are_bounded
    Dir.mktmpdir("capture-provider-validation") do |root|
      source = File.join(root, "source")
      staging = File.join(root, "staging")
      runtime = File.join(root, "runtime")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p([ source, staging, outside ])

      missing_config = provider(config: { "name" => "fixture" })
      error = assert_raises(error_class) do
        missing_config.call(
          task: "demo", source_root: source, source_sha: "a" * 40,
          staging_root: staging, runtime_root: runtime
        )
      end
      assert_match(/key not found.*command/, error.message)

      escape = assert_raises(error_class) do
        provider.send(:provider_executable, source, "../outside/provider")
      end
      assert_match(/escapes the source root/, escape.message)

      directory = File.join(source, "directory")
      FileUtils.mkdir_p(directory)
      invalid = assert_raises(error_class) do
        provider.send(:provider_executable, source, "directory")
      end
      assert_match(/regular executable file/, invalid.message)

      escaped_dir = File.join(source, "escaped")
      outside_executable = File.join(outside, "provider")
      File.write(outside_executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, outside_executable)
      File.symlink(outside, escaped_dir)
      realpath_escape = assert_raises(error_class) do
        provider.send(:provider_executable, source, "escaped/provider")
      end
      assert_match(/escapes the source root/, realpath_escape.message)

      missing = assert_raises(error_class) do
        provider.send(:provider_executable, source, "missing")
      end
      assert_match(/is unavailable/, missing.message)
    end
  end

  def test_execute_translates_every_process_result_boundary
    cases = [
      [ { "cleanup_failed" => true }, /descendants could not be terminated/ ],
      [ { "stderr_overflow" => true }, /stderr exceeded/ ],
      [
        {
          "status" => {
            "success" => false, "signaled" => true,
            "exitstatus" => nil, "termsig" => 9
          }
        },
        /signal 9/
      ]
    ]
    cases.each do |override, expected|
      subject = provider
      result = base_result.merge(override)
      subject.define_singleton_method(:supervise_provider) { |*, **| result }
      error = assert_raises(error_class) do
        subject.send(
          :execute!, [ "/bin/true" ], request: {}, source_root: "/tmp",
          environment: {}, timeout_sec: 1
        )
      end
      assert_match expected, error.message
    end

    subject = provider
    subject.define_singleton_method(:supervise_provider) { |*, **| raise Errno::EACCES, "blocked" }
    error = assert_raises(error_class) do
      subject.send(
        :execute!, [ "/bin/true" ], request: {}, source_root: "/tmp",
        environment: {}, timeout_sec: 1
      )
    end
    assert_match(/could not start.*blocked/, error.message)
  end

  def test_outer_custody_combines_primary_and_cleanup_failures
    subject = provider
    result = base_result
    provider_error = error_class
    subject.define_singleton_method(:supervise_provider_in_custody) { |*, **| result }
    subject.define_singleton_method(:read_supervisor_result) { |_reader| "" }
    subject.define_singleton_method(:wait_for_supervisor_status!) do |target, **|
      Process.waitpid(target.fetch(:pid))
      FakeStatus.new(false, true, nil, 9)
    end
    subject.define_singleton_method(:cleanup_command_custody_tree!) do |_target|
      raise provider_error, "cleanup exploded"
    end

    error = assert_raises(error_class) do
      subject.send(
        :supervise_provider, [ "/bin/true" ], request: {}, source_root: "/tmp",
        environment: {}, timeout_sec: 1
      )
    end
    assert_match(/custody root failed.*command custody also failed.*cleanup exploded/, error.message)
  end

  def test_outer_custody_bounds_result_pipe_reads
    subject = provider
    result = base_result
    subject.define_singleton_method(:supervise_provider_in_custody) { |*, **| result }
    error = with_blocked_result_reader(subject) do
      assert_raises(error_class) do
        subject.send(
          :supervise_provider, [ "/bin/true" ], request: {}, source_root: "/tmp",
          environment: {}, timeout_sec: 1
        )
      end
    end
    assert_match(/custody result exceeded its read deadline/, error.message)
  end

  def test_inner_custody_rejects_preexisting_descendants_and_serializes_child_errors
    subject = provider
    subject.define_singleton_method(:child_subreaper_enabled?) { true }
    subject.define_singleton_method(:supervisor_descendants) do
      [ { pid: 123, start_time: "1", depth: 1 } ]
    end
    error = assert_raises(error_class) do
      subject.send(
        :supervise_provider_in_custody, [ "/bin/true" ], request: {},
        source_root: "/tmp", environment: {}, timeout_sec: 1,
        deadline: nil, stdout_consumer: nil
      )
    end
    assert_match(/unexpected pre-existing descendants/, error.message)

    subject = provider
    subject.define_singleton_method(:child_subreaper_enabled?) { true }
    subject.define_singleton_method(:supervisor_descendants) { [] }
    subject.define_singleton_method(:enable_child_subreaper!) { raise "child setup exploded" }
    subject.define_singleton_method(:cleanup_parent_provider_tree!) { |_target| nil }
    result = subject.send(
      :supervise_provider_in_custody, [ "/bin/true" ], request: {},
      source_root: "/tmp", environment: {}, timeout_sec: 1,
      deadline: nil, stdout_consumer: nil
    )
    assert_match(/child setup exploded/, result.fetch("internal_error"))
  end

  def test_inner_custody_bounds_reads_and_combines_cleanup_failures
    timeout_subject = provider
    result = base_result
    timeout_subject.define_singleton_method(:child_subreaper_enabled?) { true }
    timeout_subject.define_singleton_method(:supervisor_descendants) { [] }
    timeout_subject.define_singleton_method(:enable_child_subreaper!) { nil }
    timeout_subject.define_singleton_method(:supervise_provider_child) { |*, **| result }
    timeout_subject.define_singleton_method(:cleanup_parent_provider_tree!) { |_target| nil }
    error = with_blocked_result_reader(timeout_subject) do
      assert_raises(error_class) do
        timeout_subject.send(
          :supervise_provider_in_custody, [ "/bin/true" ], request: {},
          source_root: "/tmp", environment: {}, timeout_sec: 1,
          deadline: nil, stdout_consumer: nil
        )
      end
    end
    assert_match(/supervisor result exceeded its read deadline/, error.message)

    combined = provider
    provider_error = error_class
    combined.define_singleton_method(:child_subreaper_enabled?) { true }
    combined.define_singleton_method(:supervisor_descendants) { [] }
    combined.define_singleton_method(:enable_child_subreaper!) { nil }
    combined.define_singleton_method(:supervise_provider_child) { |*, **| result }
    combined.define_singleton_method(:wait_for_supervisor_status!) do |target, **|
      Process.waitpid(target.fetch(:pid))
      FakeStatus.new(false, true, nil, 9)
    end
    combined.define_singleton_method(:cleanup_parent_provider_tree!) do |_target|
      raise provider_error, "parent cleanup exploded"
    end
    error = assert_raises(error_class) do
      combined.send(
        :supervise_provider_in_custody, [ "/bin/true" ], request: {},
        source_root: "/tmp", environment: {}, timeout_sec: 1,
        deadline: nil, stdout_consumer: nil
      )
    end
    assert_match(/supervisor failed.*parent provider custody also failed/, error.message)
  end

  def test_inner_custody_reports_subreaper_restore_failures
    subject = provider
    result = base_result
    subject.define_singleton_method(:child_subreaper_enabled?) { false }
    subject.define_singleton_method(:enable_child_subreaper!) { nil }
    subject.define_singleton_method(:disable_child_subreaper!) { raise "restore exploded" }
    subject.define_singleton_method(:supervisor_descendants) { [] }
    subject.define_singleton_method(:supervise_provider_child) { |*, **| result }
    subject.define_singleton_method(:cleanup_parent_provider_tree!) { |_target| nil }

    error = assert_raises(RuntimeError) do
      subject.send(
        :supervise_provider_in_custody, [ "/bin/true" ], request: {},
        source_root: "/tmp", environment: {}, timeout_sec: 1,
        deadline: nil, stdout_consumer: nil
      )
    end
    assert_match(/restore exploded/, error.message)
  end

  def test_command_custody_cleanup_exercises_term_kill_and_failure_paths
    target = { pid: 123, start_time: "1", depth: 0 }
    success = provider
    success.define_singleton_method(:command_custody_targets) { |_target| [ target ] }
    success.define_singleton_method(:signal_targets) { |*, **| nil }
    success.define_singleton_method(:wait_for_command_custody_exit) { |*, **| [] }
    with_replaced_singleton_method(
      Hive::ProcessKill, :captured_process_alive?, ->(_target) { true }
    ) { assert_nil success.send(:cleanup_command_custody_tree!, target) }

    failure = provider
    signals = []
    failure.define_singleton_method(:command_custody_targets) { |_target| [ target ] }
    failure.define_singleton_method(:signal_targets) { |signal, _targets| signals << signal }
    failure.define_singleton_method(:wait_for_command_custody_exit) { |*, **| [ target ] }
    error = with_replaced_singleton_method(
      Hive::ProcessKill, :captured_process_alive?, ->(_target) { true }
    ) do
      assert_raises(error_class) { failure.send(:cleanup_command_custody_tree!, target) }
    end
    assert_match(/could not terminate/, error.message)
    assert_equal %w[TERM KILL], signals
  end

  def test_command_custody_wait_and_target_inventory_are_identity_bound
    custody = { pid: 10, start_time: "1", depth: 0 }
    child = { pid: 11, start_time: "2", depth: 1 }
    subject = provider
    subject.define_singleton_method(:command_custody_targets) { |_target| [ child ] }
    subject.define_singleton_method(:reap_command_custody_root) { |_target| nil }
    subject.define_singleton_method(:signal_targets) { |*, **| nil }
    subject.define_singleton_method(:sleep) { |_seconds| nil }
    times = [ 0.0, 2.0 ]
    subject.define_singleton_method(:monotonic_now) { times.shift || 2.0 }
    alive = ->(target) { [ 10, 11 ].include?(target.fetch(:pid)) }
    remaining = with_replaced_singleton_method(
      Hive::ProcessKill, :captured_process_alive?, alive
    ) do
      subject.send(
        :wait_for_command_custody_exit, custody, [ child, child.dup ],
        deadline: 1.0, signal: "TERM"
      )
    end
    assert_equal [ 11 ], remaining.map { |entry| entry.fetch(:pid) }

    inventory_subject = provider
    inventory_subject.define_singleton_method(:confirmed_descendants) { |_pid| [ child ] }
    targets = with_replaced_singleton_method(
      Hive::ProcessKill, :captured_process_alive?, ->(_target) { true }
    ) { inventory_subject.send(:command_custody_targets, custody) }
    assert_equal [ 11, 10 ], targets.map { |entry| entry.fetch(:pid) }

    with_replaced_singleton_method(Process, :waitpid, ->(*) { raise Errno::ECHILD }) do
      assert_nil inventory_subject.send(:reap_command_custody_root, custody)
    end
  end

  def test_process_target_and_wait_status_fail_closed_on_identity_loss
    subject = provider
    error = with_replaced_singleton_method(
      Hive::ProcessKill, :process_start_time, ->(_pid) { nil }
    ) do
      assert_raises(error_class) { subject.send(:recorded_process_target!, 123, "worker") }
    end
    assert_match(/identity is unavailable/, error.message)

    target = { pid: 123, start_time: "1", depth: 0 }
    wrong_wait = with_replaced_singleton_method(
      Process, :waitpid2, ->(*) { [ 999, FakeStatus.new(true, false, 0, nil) ] }
    ) do
      assert_raises(error_class) do
        subject.send(:wait_for_supervisor_status!, target, deadline: Float::INFINITY)
      end
    end
    assert_match(/identity changed/, wrong_wait.message)

    subject.define_singleton_method(:monotonic_now) { 2.0 }
    timeout = with_replaced_singleton_method(Process, :waitpid2, ->(*) { nil }) do
      assert_raises(error_class) do
        subject.send(:wait_for_supervisor_status!, target, deadline: 1.0)
      end
    end
    assert_match(/exceeded its custody deadline/, timeout.message)

    waits = [ nil, [ 123, FakeStatus.new(true, false, 0, nil) ] ]
    subject.define_singleton_method(:monotonic_now) { 0.0 }
    status = with_replaced_singleton_method(Process, :waitpid2, ->(*) { waits.shift }) do
      with_replaced_singleton_method(
        Hive::ProcessKill, :process_start_time, ->(_pid) { "changed" }
      ) do
        subject.send(:wait_for_supervisor_status!, target, deadline: 1.0)
      end
    end
    assert status.success?

    waits = [ nil, nil ]
    changed = with_replaced_singleton_method(Process, :waitpid2, ->(*) { waits.shift }) do
      with_replaced_singleton_method(
        Hive::ProcessKill, :process_start_time, ->(_pid) { "changed" }
      ) do
        assert_raises(error_class) do
          subject.send(:wait_for_supervisor_status!, target, deadline: 1.0)
        end
      end
    end
    assert_match(/identity changed/, changed.message)

    lost = with_replaced_singleton_method(Process, :waitpid2, ->(*) { raise Errno::ECHILD }) do
      assert_raises(error_class) do
        subject.send(:wait_for_supervisor_status!, target, deadline: 1.0)
      end
    end
    assert_match(/exit status custody was lost/, lost.message)
  end

  def test_parent_cleanup_and_status_serialization_cover_remaining_boundaries
    target = { pid: 10, start_time: "1", depth: 0 }
    subject = provider
    subject.define_singleton_method(:parent_provider_targets) { |_target| [ target ] }
    subject.define_singleton_method(:signal_targets) { |*, **| nil }
    subject.define_singleton_method(:wait_for_parent_provider_exit) { |*, **| [ target ] }
    error = assert_raises(error_class) { subject.send(:cleanup_parent_provider_tree!, target) }
    assert_match(/could not terminate and verify/, error.message)

    subject = provider
    subject.define_singleton_method(:supervisor_descendants) { [] }
    targets = with_replaced_singleton_method(
      Hive::ProcessKill, :captured_process_alive?, ->(_target) { true }
    ) { subject.send(:parent_provider_targets, target) }
    assert_equal [ target ], targets
    assert_equal "exit 7", subject.send(
      :serialized_exit_detail, FakeStatus.new(false, false, 7, nil)
    )
  end

  def test_supervisor_child_rejects_dirty_parent_and_emergency_cleans_after_spawn
    subject = provider
    subject.define_singleton_method(:supervisor_descendants) do
      [ { pid: 123, start_time: "1", depth: 1 } ]
    end
    error = assert_raises(error_class) do
      subject.send(
        :supervise_provider_child, [ "/bin/true" ], request: {},
        source_root: "/tmp", environment: {}, timeout_sec: 1
      )
    end
    assert_match(/unexpected pre-existing descendants/, error.message)

    subject = provider
    subject.define_singleton_method(:supervisor_descendants) { [] }
    emergency = []
    subject.define_singleton_method(:emergency_terminate_provider!) { |pid| emergency << pid }
    circular = []
    circular << circular
    with_replaced_singleton_method(Process, :spawn, ->(*) { 321 }) do
      assert_raises(JSON::NestingError) do
        subject.send(
          :supervise_provider_child, [ "/bin/true" ], request: circular,
          source_root: "/tmp", environment: {}, timeout_sec: 1
        )
      end
    end
    assert_equal [ 321 ], emergency
  end

  def test_stream_and_io_error_paths_fail_closed
    subject = provider
    io = Object.new
    io.define_singleton_method(:read_nonblock) { |*, **| raise IOError, "closed" }
    io.define_singleton_method(:close) { nil }
    stream = { data: +"".b, limit: 10, overflow: false, open: true, consumer: nil,
               consumer_error: nil }
    with_replaced_singleton_method(IO, :select, ->(*) { [ [ io ], [], [] ] }) do
      subject.send(:drain_provider_streams, { io => stream }, 0)
    end
    refute stream.fetch(:open)

    consumer = Object.new
    consumer.define_singleton_method(:finish) { raise "finish exploded" }
    stream = { consumer: consumer, consumer_error: nil, overflow: false }
    subject.send(:finish_provider_stream_consumer, stream)
    assert_equal "finish exploded", stream.fetch(:consumer_error)
    assert stream.fetch(:overflow)
  end

  def test_supervisor_cleanup_ignores_a_pipe_already_closed_by_another_thread
    bad_reader = Object.new
    bad_reader.define_singleton_method(:closed?) { false }
    bad_reader.define_singleton_method(:close) { raise IOError, "closed concurrently" }
    writer = Object.new
    writer.define_singleton_method(:closed?) { false }
    writer.define_singleton_method(:close) { nil }
    pipe_calls = 0
    pipe = lambda do
      pipe_calls += 1
      raise RuntimeError, "pipe setup failed" if pipe_calls > 1

      [ bad_reader, writer ]
    end

    error = with_replaced_singleton_method(IO, :pipe, pipe) do
      assert_raises(RuntimeError) do
        provider.send(
          :supervise_provider_child, [ "/bin/true" ], request: {},
          source_root: "/tmp", environment: {}, timeout_sec: 1
        )
      end
    end

    assert_equal "pipe setup failed", error.message
  end

  def test_linux_process_inventory_handles_disappearance_and_permission_failures
    subject = provider
    subject.define_singleton_method(:linux_child_pids) do |pid, required:|
      pid == 1 && required ? [ 2 ] : []
    end
    with_replaced_singleton_method(
      Hive::ProcessKill, :process_start_time, ->(_pid) { nil }
    ) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { false }) do
        assert_empty subject.send(:linux_descendant_snapshot, 1)
      end
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, ->(_pid) { true }) do
        error = assert_raises(error_class) { subject.send(:linux_descendant_snapshot, 1) }
        assert_match(/identity custody is unavailable/, error.message)
      end
    end

    subject = provider
    with_replaced_singleton_method(Dir, :children, ->(_path) { [ "1" ] }) do
      with_replaced_singleton_method(File, :read, ->(_path) { raise Errno::ENOENT }) do
        assert_empty subject.send(:linux_child_pids, 1, required: true)
      end
    end
    with_replaced_singleton_method(Dir, :children, ->(_path) { raise Errno::ENOENT }) do
      assert_empty subject.send(:linux_child_pids, 1, required: false)
      assert_raises(error_class) { subject.send(:linux_child_pids, 1, required: true) }
    end
    with_replaced_singleton_method(Dir, :children, ->(_path) { raise Errno::EACCES }) do
      assert_raises(error_class) { subject.send(:linux_child_pids, 1, required: false) }
    end
  end

  def test_emergency_group_signaling_wait_and_pipe_errors_are_bounded
    subject = provider
    calls = []
    subject.define_singleton_method(:terminate_supervised_tree!) { |*, **| calls << :terminated }
    subject.define_singleton_method(:wait_status) { |_pid| nil }
    subject.define_singleton_method(:reap_supervised_children) { calls << :reaped }
    subject.send(:emergency_terminate_provider!, 123)
    assert_equal %i[terminated reaped], calls

    subject = provider
    calls = []
    provider_error = error_class
    subject.define_singleton_method(:terminate_supervised_tree!) do |*, **|
      raise provider_error, "fail"
    end
    subject.define_singleton_method(:wait_status) { |_pid| nil }
    subject.define_singleton_method(:signal_provider_group) { |signal, _pid| calls << signal }
    subject.define_singleton_method(:sleep) { |_seconds| nil }
    subject.define_singleton_method(:reap_supervised_children) { calls << "reaped" }
    subject.send(:emergency_terminate_provider!, 123)
    assert_equal %w[TERM KILL reaped], calls

    subject = provider
    signals = []
    with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
      subject.send(:signal_provider_group, "TERM", 123)
    end
    assert_equal [ [ "TERM", -123 ], [ "TERM", 123 ] ], signals
    with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
      assert_nil subject.send(:signal_provider_group, "TERM", 123)
    end
    with_replaced_singleton_method(Process, :waitpid2, ->(*) { raise Errno::ECHILD }) do
      assert_nil subject.send(:wait_status, 123)
    end

    writer = Object.new
    writer.define_singleton_method(:write) { |_bytes| raise IOError, "closed" }
    assert_nil subject.send(:write_supervisor_result, writer, { "ok" => true })
  end

  def test_supervisor_result_size_and_decode_validation_are_bounded
    subject = provider
    reader = StringIO.new("x" * (described_class::SUPERVISOR_RESULT_MAX_BYTES + 1))
    error = assert_raises(error_class) { subject.send(:read_supervisor_result, reader) }
    assert_match(/exceeded its limit/, error.message)

    [ "{", "[]", '{"stdout":"!","stderr":""}', "{}" ].each do |raw|
      error = assert_raises(error_class) { subject.send(:decode_supervisor_result, raw) }
      assert_match(/invalid result/, error.message)
    end
  end

  def test_subreaper_platform_failures_are_actionable
    subject = provider
    original_platform = RUBY_PLATFORM
    original_verbose = $VERBOSE
    $VERBOSE = nil
    Object.send(:remove_const, :RUBY_PLATFORM)
    Object.const_set(:RUBY_PLATFORM, "arm64-darwin26")
    %i[enable_child_subreaper! child_subreaper_enabled?].each do |method|
      error = assert_raises(error_class) { subject.send(method) }
      assert_match(/requires Linux/, error.message)
    end
  ensure
    Object.send(:remove_const, :RUBY_PLATFORM)
    Object.const_set(:RUBY_PLATFORM, original_platform)
    $VERBOSE = original_verbose
  end

  def test_subreaper_dynamic_link_failures_are_actionable
    subject = provider
    failing_function = ->(*) { raise Fiddle::DLError, "missing prctl" }
    with_replaced_singleton_method(Fiddle::Function, :new, failing_function) do
      %i[enable_child_subreaper! disable_child_subreaper! child_subreaper_enabled?].each do |method|
        error = assert_raises(error_class) { subject.send(method) }
        assert_match(/subreaper custody/, error.message)
      end
    end
  end

  def test_result_shape_artifact_and_inventory_validation_fail_closed
    base = {
      "schema" => described_class::RESULT_SCHEMA,
      "schema_version" => described_class::RESULT_SCHEMA_VERSION,
      "status" => "captured",
      "artifacts" => [],
      "evidence" => {},
      "cleanup" => described_class::CLEANUP,
      "diagnostic" => nil
    }
    cases = [
      [ base.merge("schema_version" => 99), /unsupported result schema/ ],
      [ base.merge("status" => "unknown"), /invalid status/ ],
      [ base.merge("artifacts" => {}), /invalid artifacts/ ],
      [ base.merge("diagnostic" => 123), /diagnostic is invalid/ ],
      [ base.merge("diagnostic" => "unexpected"), /must have a null diagnostic/ ]
    ]
    cases.each do |document, expected|
      error = assert_raises(error_class) { provider.send(:validate_result_shape!, document) }
      assert_match expected, error.message
    end

    assert_raises(error_class) { provider.send(:validate_artifacts!, [], "/tmp") }
    invalid = assert_raises(error_class) do
      provider.send(:validate_artifacts!, [ { "file" => "x.png" } ], "/tmp")
    end
    assert_match(/invalid shape/, invalid.message)

    Dir.mktmpdir("provider-artifacts") do |root|
      empty = File.join(root, "empty.png")
      File.write(empty, "")
      invalid = assert_raises(error_class) do
        provider.send(:validate_artifacts!, [ artifact_entry(empty) ], root)
      end
      assert_match(/invalid size/, invalid.message)

      Dir.mktmpdir("provider-outside") do |outside|
        outside_path = File.join(outside, "proof.png")
        File.write(outside_path, "png")
        linked_root = File.join(root, "linked")
        File.symlink(outside, linked_root)
        escaped = assert_raises(error_class) do
          provider.send(:validate_artifacts!, [ artifact_entry(outside_path) ], linked_root)
        end
        assert_match(/escapes staging/, escaped.message)
      end

      sized = File.join(root, "sized.png")
      File.write(sized, "png")
      entry = artifact_entry(sized).merge("bytes" => 99)
      mismatch = assert_raises(error_class) do
        provider.send(:validate_artifacts!, [ entry ], root)
      end
      assert_match(/size does not match/, mismatch.message)
    end

    mismatch = assert_raises(error_class) do
      provider.send(:validate_staging_inventory!, "/tmp", [ { "file" => "missing.png" } ])
    end
    assert_match(/undeclared or incomplete/, mismatch.message)
  end

  def test_media_validation_covers_supported_formats_and_malformed_probe_results
    formats = {
      "proof.jpg" => [ "mjpeg", {} ],
      "proof.jpeg" => [ "mjpeg", {} ],
      "proof.gif" => [ "gif", {} ],
      "proof.webp" => [ "webp", {} ],
      "proof.webm" => [ "vp9", { "format_name" => "matroska,webm", "duration" => "1.0" } ],
      "proof.mp4" => [ "h264", { "format_name" => "mov,mp4", "duration" => "1.0" } ]
    }
    formats.each do |filename, (codec, format)|
      subject = provider
      results = [
        base_result.merge(
          "stdout" => JSON.generate(
            "streams" => [ { "codec_type" => "video", "codec_name" => codec } ],
            "format" => format
          )
        ),
        base_result
      ]
      subject.define_singleton_method(:media_tool_result) { |*, **| results.shift }
      with_replaced_singleton_method(
        Hive::InvokedBinary, :which, ->(name, **) { "/bin/#{name}" }
      ) do
        assert_nil subject.send(:validate_media_content!, "/tmp/media", filename, "/tmp")
      end
    end

    subject = provider
    results = [ base_result.merge("stdout" => "{"), base_result ]
    subject.define_singleton_method(:media_tool_result) { |*, **| results.shift }
    error = with_replaced_singleton_method(
      Hive::InvokedBinary, :which, ->(name, **) { "/bin/#{name}" }
    ) do
      assert_raises(error_class) do
        subject.send(:validate_media_content!, "/tmp/media", "proof.png", "/tmp")
      end
    end
    assert_match(/not valid decodable PNG/, error.message)

    subject = provider
    results = [
      base_result.merge(
        "stdout" => JSON.generate(
          "streams" => [ { "codec_type" => "video", "codec_name" => "unknown" } ]
        )
      ),
      base_result
    ]
    subject.define_singleton_method(:media_tool_result) { |*, **| results.shift }
    error = with_replaced_singleton_method(
      Hive::InvokedBinary, :which, ->(name, **) { "/bin/#{name}" }
    ) do
      assert_raises(error_class) do
        subject.send(:validate_media_content!, "/tmp/media", "proof.avi", "/tmp")
      end
    end
    assert_match(/not valid decodable AVI/, error.message)

    assert_equal false, provider.send(:playable_video?, {}, nil, /webm/)
    assert_equal false, provider.send(
      :playable_video?, { "format" => "webm" }, {}, /webm/
    )
    assert_equal false, provider.send(
      :playable_video?, { "format" => { "format_name" => "mov", "duration" => "1" } },
      {}, /webm/
    )
    assert_equal false, provider.send(
      :playable_video?, { "format" => { "format_name" => "webm", "duration" => "0" } },
      {}, /webm/
    )
  end

  def test_private_directory_rejects_non_directories
    Dir.mktmpdir("provider-private-dir") do |root|
      path = File.join(root, "file")
      File.write(path, "x")
      error = assert_raises(error_class) do
        provider.send(:ensure_private_directory!, path, "fixture")
      end
      assert_match(/owned regular directory/, error.message)
    end
  end

  private

  def described_class
    Hive::Web::ProjectCaptureProvider
  end

  def error_class
    described_class::ProviderError
  end

  def provider(config: nil)
    described_class.new(
      config: config || {
        "name" => "fixture", "command" => [ "bin/provider" ], "timeout_sec" => 1
      },
      environment: { "PATH" => ENV.fetch("PATH", "") }
    )
  end

  def base_result
    {
      "stdout" => "",
      "stderr" => "",
      "stdout_overflow" => false,
      "stderr_overflow" => false,
      "stdout_consumer_error" => nil,
      "timed_out" => false,
      "leftover_processes" => false,
      "cleanup_failed" => false,
      "status" => {
        "success" => true, "signaled" => false, "exitstatus" => 0, "termsig" => nil
      }
    }
  end

  def artifact_entry(path)
    {
      "file" => File.basename(path),
      "bytes" => File.size(path),
      "sha256" => Digest::SHA256.file(path).hexdigest
    }
  end

  def with_blocked_result_reader(subject)
    gate = Queue.new
    subject.define_singleton_method(:read_supervisor_result) { |_reader| gate.pop }
    yield
  ensure
    gate << ""
  end
end
