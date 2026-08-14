require "test_helper"
require "stringio"
require "hive/artifacts/browser_gateway"

class ArtifactsBrowserGatewayCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Gateway = Hive::Artifacts::BrowserGateway

  def test_start_and_close_normalize_os_failures
    Dir.mktmpdir("hive-browser-gateway-start") do |root|
      gateway = build_gateway(root)
      error = with_replaced_singleton_method(
        UNIXServer, :new, ->(*) { raise Errno::EACCES, "denied" }
      ) do
        assert_raises(Gateway::GatewayError) { gateway.start! }
      end
      assert_match(/unavailable/, error.message)

      failing = build_gateway(root)
      failing.instance_variable_set(:@server, Object.new.tap do |server|
        server.define_singleton_method(:closed?) { false }
        server.define_singleton_method(:close) { raise IOError, "closed" }
      end)
      refute failing.close
    end
  end

  def test_accept_loop_retries_transient_system_failure_then_stops
    gateway = Gateway.allocate
    gateway.instance_variable_set(:@closed, false)
    calls = 0
    server = Object.new
    server.define_singleton_method(:accept) do
      calls += 1
      raise Errno::ECONNABORTED if calls == 1

      raise IOError, "closed"
    end
    gateway.instance_variable_set(:@server, server)

    assert_nil gateway.send(:accept_requests)
    assert_equal 2, calls
  end

  def test_request_boundary_returns_bounded_protocol_errors
    Dir.mktmpdir("hive-browser-gateway-protocol") do |root|
      gateway = build_gateway(root)

      missing = protocol_client(nil)
      gateway.send(:handle, missing)
      assert_equal 64, JSON.parse(missing.writes.last).fetch("status")

      oversized = protocol_client("x" * (Gateway::MAX_REQUEST_BYTES + 1))
      gateway.send(:handle, oversized)
      assert_match(/oversized/, JSON.parse(oversized.writes.last).fetch("stderr"))

      invalid = protocol_client("{\n")
      gateway.send(:handle, invalid)
      assert_equal 64, JSON.parse(invalid.writes.last).fetch("status")

      gateway.define_singleton_method(:execute) { |_| raise RuntimeError, "secret" }
      failed = protocol_client("{\"argv\":[\"snapshot\"]}\n")
      gateway.send(:handle, failed)
      response = JSON.parse(failed.writes.last)
      assert_equal 70, response.fetch("status")
      refute_includes response.fetch("stderr"), "secret"

      unwritable = Object.new
      unwritable.define_singleton_method(:write) { |_| raise Errno::EPIPE }
      assert_nil gateway.send(:respond, unwritable, {})
    end
  end

  def test_argument_admission_covers_every_command_shape
    Dir.mktmpdir("hive-browser-gateway-argv") do |root|
      gateway = build_gateway(root)
      invalid = [
        nil, [], Array.new(Gateway::MAX_ARGUMENTS + 1, "x"), [ "" ],
        [ "snapshot", "bad\nargument" ], [ "snapshot", "--socket" ],
        [ "unknown" ], [ "get", "cdp-url" ], [ "open" ],
        [ "open", "http://capture.invalid", "extra" ],
        [ "open", "http://[" ], [ "open", "http://user@capture.invalid" ],
        [ "screenshot", "bad.jpg" ],
        [ "screenshot", "proof.png", "--full", "--full" ],
        [ "record", "stop" ], [ "record", "pause" ],
        [ "record", "start", "bad.png" ]
      ]
      invalid.each do |argv|
        assert_raises(Gateway::GatewayError, argv.inspect) do
          gateway.send(:validate_argv!, argv)
        end
      end

      assert_equal [ "open", "http://capture.invalid/path" ],
                   gateway.send(:validate_argv!, [ "open", "http://capture.invalid/path" ])
      screenshot = gateway.send(
        :validate_argv!, [ "screenshot", "proof.png", "--full", "--annotate" ]
      )
      assert_match(/proof\.png\z/, screenshot.fetch(1))
      started = gateway.send(
        :validate_argv!, [ "record", "start", "flow.webm", "http://capture.invalid/flow" ]
      )
      assert_equal %w[record start], started.first(2)
      assert_raises(Gateway::GatewayError) do
        gateway.send(:validate_argv!, [ "record", "start", "other.webm" ])
      end
      assert_equal %w[record stop], gateway.send(:validate_argv!, %w[record stop])
    end
  end

  def test_failed_record_start_resets_state_and_media_publication_is_fail_closed
    Dir.mktmpdir("hive-browser-gateway-media") do |root|
      gateway = build_gateway(root, runner: ->(*) { [ "", "failed", 1 ] })
      started = gateway.send(:validate_argv!, %w[record start flow.webm])
      assert_equal 1, gateway.send(:execute, started).last
      assert_nil gateway.instance_variable_get(:@pending_record)

      directory = File.join(root, "directory")
      Dir.mkdir(directory)
      assert_raises(Gateway::GatewayError) do
        gateway.send(:publish_media!, directory, File.join(root, "out.png"))
      end
      assert_raises(Gateway::GatewayError) do
        gateway.send(:publish_media!, File.join(root, "missing"), File.join(root, "out.png"))
      end

      source = File.join(root, "source.png")
      destination = File.join(root, "exists.png")
      File.binwrite(source, "png")
      File.binwrite(destination, "old")
      assert_raises(Gateway::GatewayError) do
        gateway.send(:publish_media!, source, destination)
      end
      refute_path_exists source

      source = File.join(root, "raced.png")
      File.binwrite(source, "png")
      with_replaced_singleton_method(File, :unlink, ->(*) { raise Errno::ENOENT }) do
        gateway.send(:publish_media!, source, File.join(root, "published.png"))
      end
    end
  end

  def test_native_runner_bounds_output_and_normalizes_timeout_and_missing_binary
    Dir.mktmpdir("hive-browser-gateway-runner") do |root|
      gateway = build_gateway(root)
      gateway.instance_variable_set(:@private_root, root)

      stdout, stderr, status = gateway.send(
        :run_command, {}, [ RbConfig.ruby, "-e", "$stdout.write('ok'); $stderr.write('warn')" ]
      )
      assert_equal [ "ok", "warn", 0 ], [ stdout, stderr, status ]

      _stdout, error, status = gateway.send(:run_command, {}, [ "/missing/browser" ])
      assert_equal 127, status
      assert_match(/failed/, error)

      gateway.define_singleton_method(:terminate_process_group) { |_| nil }
      timed = with_replaced_singleton_method(
        Timeout, :timeout, ->(*) { raise Timeout::Error }
      ) do
        gateway.send(:run_command, {}, [ RbConfig.ruby, "-e", "sleep 0.1" ])
      end
      assert_equal 124, timed.last

      bounded = gateway.send(:bounded, "x" * (Gateway::MAX_OUTPUT_BYTES + 1))
      assert_equal Gateway::MAX_OUTPUT_BYTES + 26, bounded.bytesize
      assert_includes bounded, "output truncated"

      fresh = build_gateway(root)
      kills = []
      with_replaced_singleton_method(Process, :kill, ->(*args) { kills << args }) do
        fresh.send(:terminate_process_group, 123)
      end
      assert_equal [ [ "TERM", -123 ], [ "KILL", -123 ] ], kills
      with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
        assert_nil fresh.send(:terminate_process_group, 123)
      end
      assert_nil gateway.send(:remove_owned_root, File.join(root, "missing"))
      with_replaced_singleton_method(File, :directory?, ->(*) { true }) do
        with_replaced_singleton_method(File, :lstat, ->(*) { raise Errno::ENOENT }) do
          assert_nil fresh.send(:remove_owned_root, File.join(root, "raced"))
        end
      end
    end
  end

  private

  def build_gateway(root, runner: ->(*) { [ "", "", 0 ] })
    gateway = Gateway.new(
      environment: {}, argv_prefix: [ "agent-browser" ], writable_root: root,
      origin: "http://capture.invalid", runner: runner
    )
    private_root = Dir.mktmpdir("hive-browser-private", root)
    gateway.instance_variable_set(:@private_root, private_root)
    gateway
  end

  def protocol_client(line)
    writes = []
    Object.new.tap do |client|
      client.define_singleton_method(:gets) { |_| line }
      client.define_singleton_method(:write) { |value| writes << value }
      client.define_singleton_method(:writes) { writes }
    end
  end
end
