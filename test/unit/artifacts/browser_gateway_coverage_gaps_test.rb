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
        Dir, :mktmpdir, ->(*) { raise Errno::EACCES, "denied" }
      ) do
        assert_raises(Gateway::GatewayError) { gateway.start! }
      end
      assert_match(/unavailable/, error.message)

      failing = build_gateway(root)
      failing.instance_variable_set(:@private_root, File.join(root, "missing"))
      assert failing.close
    end
  end

  def test_request_boundary_returns_bounded_protocol_errors
    Dir.mktmpdir("hive-browser-gateway-protocol") do |root|
      gateway = build_gateway(root)

      missing = gateway.call(nil)
      assert_equal 64, missing.fetch("status")

      gateway.define_singleton_method(:execute) { |_| raise RuntimeError, "secret" }
      response = gateway.call([ "snapshot" ])
      assert_equal 70, response.fetch("status")
      refute_includes response.fetch("stderr"), "secret"
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

      oversized = File.join(root, "oversized.png")
      File.binwrite(oversized, "large")
      bounded = Gateway.new(
        environment: {}, argv_prefix: [ "agent-browser" ], writable_root: root,
        origin: "http://capture.invalid", max_media_bytes: 4
      )
      assert_raises(Gateway::GatewayError) do
        bounded.send(:publish_media!, oversized, File.join(root, "bounded.png"))
      end
      refute_path_exists File.join(root, "bounded.png")

      callback_source = File.join(root, "callback.png")
      callback_destination = File.join(root, "callback-published.png")
      File.binwrite(callback_source, "png")
      callback = Gateway.new(
        environment: {}, argv_prefix: [ "agent-browser" ], writable_root: root,
        origin: "http://capture.invalid",
        on_publish: ->(*) { raise "receipt failed" }
      )
      assert_raises(RuntimeError) do
        callback.send(:publish_media!, callback_source, callback_destination)
      end
      refute_path_exists callback_destination
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
end
