require "test_helper"
require "hive/artifacts/browser_gateway"

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

      response = gateway.call([ "snapshot", "-i" ])
      assert response.fetch("ok")
      assert_equal "interactive output\n", response.fetch("stdout")

      response = gateway.call([ "screenshot", "review.png", "--full" ])
      assert response.fetch("ok")
      assert_equal "png-evidence", File.binread(File.join(root, "review.png"))
      assert_includes response.fetch("stdout"), File.join(root, "review.png")
      refute_match(/hive-browser-output/, response.fetch("stdout"))

      assert gateway.call(%w[record start flow.webm]).fetch("ok")
      assert gateway.call(%w[record stop]).fetch("ok")
      assert_equal "webm-evidence", File.binread(File.join(root, "flow.webm"))

      assert calls.any? { |argv| argv.include?("snapshot") }
      assert calls.none? { |argv| argv.any? { |item| item.include?("../") } }
    ensure
      private_root = gateway&.instance_variable_get(:@private_root)
      gateway&.close
      refute File.exist?(private_root) if private_root
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

      [
        [ "open", [ "http://127.0.0.1/private" ] ],
        [ "screenshot", [ "../escape.png" ] ],
        [ "pdf", [ "escape.pdf" ] ],
        [ "snapshot", [ "--socket", "/tmp/other.sock" ] ],
        [ "get", [ "cdp-url" ] ]
      ].each do |command, arguments|
        response = gateway.call([ command, *arguments ])
        refute response.fetch("ok")
        assert_equal 64, response.fetch("status")
      end

      assert_empty calls
      refute File.exist?(File.join(File.dirname(root), "escape.png"))
    ensure
      gateway&.close
    end
  end
end
