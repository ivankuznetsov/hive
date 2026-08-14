require "test_helper"
require "hive/artifacts/browser_gateway"
require "hive/commands/evidence"

class ArtifactsBrowserGatewayTest < Minitest::Test
  def test_closed_gateway_confines_screenshot_and_recording_publication
    Dir.mktmpdir("hive-browser-gateway-test") do |root|
      calls = []
      recording = nil
      runner = lambda do |_environment, argv|
        calls << argv
        if (index = argv.index("screenshot"))
          File.binwrite(argv.fetch(index + 1), "png-evidence")
          [ "saved #{argv.fetch(index + 1)}\n", "", 0 ]
        elsif argv.last(3).first(2) == %w[record start]
          recording = argv[-1]
          [ "recording\n", "", 0 ]
        elsif argv.last(2) == %w[record stop]
          File.binwrite(recording, "webm-evidence")
          [ "saved #{recording}\n", "", 0 ]
        else
          [ "interactive output\n", "", 0 ]
        end
      end
      gateway = Hive::Artifacts::BrowserGateway.new(
        environment: {}, argv_prefix: %w[agent-browser --session evidence],
        writable_root: root, origin: "http://capture.invalid", runner: runner
      ).start!
      environment = { "HIVE_EVIDENCE_BROWSER_SOCKET" => gateway.socket_path }

      out, = capture_io do
        Hive::Commands::Evidence.new(
          "browser", "snapshot", command: [ "-i" ], environment: environment
        ).call
      end
      assert_equal "interactive output\n", out

      out, = capture_io do
        Hive::Commands::Evidence.new(
          "browser", "screenshot", command: %w[review.png --full],
          environment: environment
        ).call
      end
      assert_equal "png-evidence", File.binread(File.join(root, "review.png"))
      assert_includes out, File.join(root, "review.png")
      refute_match(/hive-browser-output/, out)

      capture_io do
        Hive::Commands::Evidence.new(
          "browser", "record", command: %w[start flow.webm],
          environment: environment
        ).call
      end
      capture_io do
        Hive::Commands::Evidence.new(
          "browser", "record", command: %w[stop], environment: environment
        ).call
      end
      assert_equal "webm-evidence", File.binread(File.join(root, "flow.webm"))

      assert calls.any? { |argv| argv.include?("snapshot") }
      assert calls.none? { |argv| argv.any? { |item| item.include?("../") } }
    ensure
      socket_root = gateway&.socket_root
      gateway&.close
      refute File.exist?(socket_root) if socket_root
    end
  end

  def test_gateway_rejects_other_origins_paths_and_unbounded_commands
    Dir.mktmpdir("hive-browser-gateway-test") do |root|
      calls = []
      gateway = Hive::Artifacts::BrowserGateway.new(
        environment: {}, argv_prefix: [ "agent-browser" ], writable_root: root,
        origin: "http://capture.invalid", runner: ->(_environment, argv) {
          calls << argv
          [ "", "", 0 ]
        }
      ).start!
      environment = { "HIVE_EVIDENCE_BROWSER_SOCKET" => gateway.socket_path }

      [
        [ "open", [ "http://127.0.0.1/private" ] ],
        [ "screenshot", [ "../escape.png" ] ],
        [ "pdf", [ "escape.pdf" ] ],
        [ "snapshot", [ "--socket", "/tmp/other.sock" ] ],
        [ "get", [ "cdp-url" ] ]
      ].each do |command, arguments|
        _out, _err = capture_io do
          assert_raises(Hive::UsageError) do
            Hive::Commands::Evidence.new(
              "browser", command, command: arguments, environment: environment
            ).call
          end
        end
      end

      assert_empty calls
      refute File.exist?(File.join(File.dirname(root), "escape.png"))
    ensure
      gateway&.close
    end
  end
end
