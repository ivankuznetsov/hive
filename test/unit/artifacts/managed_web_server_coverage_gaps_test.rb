require "test_helper"
require "hive/artifacts/managed_web_server"

class ArtifactsManagedWebServerCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Server = Hive::Artifacts::ManagedWebServer

  def test_start_reports_server_and_cleanup_failures_with_bounded_diagnostics
    with_server_root do |source, work|
      factory = lambda do |**attributes|
        Object.new.tap do |server|
          server.define_singleton_method(:call) do
            attributes.fetch(:error).write("diagnostic detail")
            attributes.fetch(:error).flush
            raise RuntimeError, "server exploded"
          end
        end
      end
      session = build_server(source, work, factory: factory)

      error = assert_raises(Server::ServerError) { session.start! }
      assert_match(/no readiness receipt/, error.message)
      assert_match(/server exploded/, error.message)
      assert_match(/diagnostic detail/, error.message)
    end
  end

  def test_start_normalizes_invalid_json_and_cleanup_error
    with_server_root do |source, work|
      factory = readiness_factory("not-json\n")
      clean_session = build_server(source, work, factory: factory)
      assert_raises(Server::ServerError) { clean_session.start! }

      FileUtils.rm_f(File.join(work, ".hive-web-server.log"))
      session = build_server(source, work, factory: factory)
      session.define_singleton_method(:close) { raise RuntimeError, "cleanup failed" }

      error = assert_raises(Server::ServerError) { session.start! }
      assert_match(/startup failed/, error.message)
      assert_match(/cleanup: cleanup failed/, error.message)
    end
  end

  def test_readiness_rejects_malformed_and_unowned_receipts
    with_server_root do |source, work|
      session = build_server(source, work)
      base = {
        "schema" => Hive::Web::CaptureRuntime::SCHEMA,
        "schema_version" => Hive::Web::CaptureRuntime::SCHEMA_VERSION,
        "lifecycle_id" => "token", "source_sha" => "a" * 40,
        "readiness_url" => "http://127.0.0.1:4567/health"
      }
      assert_nil session.send(:validate_readiness!, base)

      assert_raises(Server::ServerError) do
        session.send(:validate_readiness!, base.merge("lifecycle_id" => "other"))
      end
      assert_raises(Server::ServerError) do
        session.send(:validate_readiness!, base.merge("readiness_url" => "http://["))
      end
    end
  end

  def test_close_times_out_and_terminates_the_server_thread
    session = Server.allocate
    writer = Object.new
    writer.define_singleton_method(:closed?) { false }
    writer.define_singleton_method(:close) { true }
    killed = joined = false
    thread = Object.new
    thread.define_singleton_method(:kill) { killed = true }
    thread.define_singleton_method(:join) { joined = true }
    session.instance_variable_set(:@control_writer, writer)
    session.instance_variable_set(:@thread, thread)
    session.instance_variable_set(:@errors, [])
    session.instance_variable_set(:@log_path, "/missing/managed-web.log")

    with_replaced_singleton_method(Timeout, :timeout, ->(*) { raise Timeout::Error }) do
      assert_raises(Server::ServerError) { session.close }
    end
    assert killed
    assert joined

    raising_io = Object.new
    raising_io.define_singleton_method(:closed?) { false }
    raising_io.define_singleton_method(:close) { raise IOError, "already closed" }
    clean = Server.allocate
    clean.instance_variable_set(:@readiness_reader, raising_io)
    clean.instance_variable_set(:@errors, [])
    assert clean.close
  end

  def test_default_server_factory_and_diagnostic_read_failure_are_normalized
    session = Server.allocate
    session.instance_variable_set(:@source_root, "/source")
    session.instance_variable_set(:@runtime_root, "/runtime")
    session.instance_variable_set(:@lifecycle_token, "token")
    session.instance_variable_set(:@port, 0)
    session.instance_variable_set(:@environment, {})
    session.instance_variable_set(:@log, nil)
    session.instance_variable_set(:@log_path, "/missing/log")
    session.instance_variable_set(:@errors, [ RuntimeError.new("worker") ])
    built = Object.new
    captured = nil

    replacement = ->(**attributes) do
      captured = attributes
      built
    end
    actual = with_replaced_singleton_method(
      Hive::Commands::Web::CaptureServer, :new, replacement
    ) do
      session.send(:build_server, control_io: StringIO.new, output: StringIO.new)
    end
    assert_same built, actual
    assert_equal "/source", captured.fetch(:source_root)
    assert_equal "prefix: worker", session.send(:diagnostic, "prefix")
  end

  private

  def with_server_root
    Dir.mktmpdir("hive-managed-web-server-gaps") do |root|
      source = File.join(root, "source")
      work = File.join(root, "work")
      FileUtils.mkdir_p(source)
      yield source, work
    end
  end

  def build_server(source, work, factory: nil)
    Server.new(
      source_root: source, source_sha: "a" * 40, writable_root: work,
      lifecycle_token: "token", server_factory: factory
    )
  end

  def readiness_factory(line)
    lambda do |**attributes|
      Object.new.tap do |server|
        server.define_singleton_method(:call) do
          attributes.fetch(:output).write(line)
          attributes.fetch(:output).flush
          attributes.fetch(:control_io).read
        end
      end
    end
  end
end
