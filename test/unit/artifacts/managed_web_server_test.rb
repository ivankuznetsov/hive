require "test_helper"
require "hive/artifacts/managed_web_server"

class ArtifactsManagedWebServerTest < Minitest::Test
  def test_controller_owns_readiness_and_control_channel_until_close
    Dir.mktmpdir("hive-managed-web-server") do |root|
      source = File.join(root, "source")
      work = File.join(root, "work")
      FileUtils.mkdir_p(source)
      source_sha = "a" * 40
      factory = lambda do |**attributes|
        Object.new.tap do |server|
          server.define_singleton_method(:call) do
            attributes.fetch(:output).puts(JSON.generate(
              "schema" => Hive::Web::CaptureRuntime::SCHEMA,
              "schema_version" => Hive::Web::CaptureRuntime::SCHEMA_VERSION,
              "lifecycle_id" => attributes.fetch(:lifecycle_token),
              "readiness_url" => "http://127.0.0.1:45_678/health".delete("_"),
              "source_sha" => source_sha,
              "cache_key" => "b" * 64
            ))
            attributes.fetch(:output).flush
            attributes.fetch(:control_io).read
          end
        end
      end
      session = Hive::Artifacts::ManagedWebServer.new(
        source_root: source, source_sha: source_sha, writable_root: work,
        lifecycle_token: "evidence-token-123", server_factory: factory
      )

      receipt = session.start!

      assert_equal "ready", receipt.fetch("status")
      assert_equal 45_678, receipt.fetch("app_port")
      assert_equal File.join(work, ".hive-web-runtime", "hive-home"),
                   receipt.fetch("hive_home")
      assert session.close
    end
  end
end
