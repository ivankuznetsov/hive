require_relative "../../test_helper"
require_relative "releases_stub_server"
require "hive/update_check"

class E2EReleasesStubServerTest < Minitest::Test
  def test_serves_controlled_tag_to_a_real_update_check_probe
    server = Hive::E2E::ReleasesStubServer.new(tag: "v999.0.0")
    begin
      # A real UpdateCheck process pointed at the stub (no http: injection)
      # must parse the controlled tag and report "behind".
      ENV["HIVE_RELEASES_API_URL"] = server.url
      result = Hive::UpdateCheck.latest(current: "0.1.0")
      assert result, "probe against the stub should return a result"
      assert_equal "999.0.0", result.latest
      assert result.behind?
    ensure
      ENV.delete("HIVE_RELEASES_API_URL")
      server.stop
    end
  end

  def test_stop_releases_the_port
    server = Hive::E2E::ReleasesStubServer.new(tag: "v1.0.0")
    port = URI(server.url).port
    server.stop
    # Re-binding the same port must not raise Errno::EADDRINUSE — that raise-free
    # rebind is the proof stop released the port. Assert it's the same port.
    rebind = TCPServer.new("127.0.0.1", port)
    assert_equal port, rebind.addr[1], "stop should free the port for rebinding"
    rebind.close
  end
end
