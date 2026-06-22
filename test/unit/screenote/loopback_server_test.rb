require "test_helper"
require "socket"
require "hive/screenote/loopback_server"

class ScreenoteLoopbackServerTest < Minitest::Test
  include HiveTestHelper

  def test_wait_for_callback_captures_code_and_closes_server
    server = Hive::Screenote::LoopbackServer.new
    port = server.port
    assert_equal "http://127.0.0.1:#{port}/callback", server.redirect_uri
    waiter = wait_for(server)

    response = raw_get(server, "/callback?code=code-123&state=state-123")
    result = waiter.value

    assert_equal({ "code" => "code-123", "state" => "state-123" }, result)
    assert_includes response, "Screenote connected"
    assert_port_released(port)
  end

  def test_wait_for_callback_rejects_authorization_error
    server = Hive::Screenote::LoopbackServer.new
    waiter = wait_for(server)

    response = raw_get(server, "/callback?error=access_denied&error_description=Nope")
    err = assert_raises(Hive::Error) { waiter.value }

    assert_match(/Nope/, err.message)
    assert_includes response, "Screenote connection failed"
  end

  def test_wait_for_callback_rejects_state_mismatch_and_missing_code
    server = Hive::Screenote::LoopbackServer.new
    waiter = wait_for(server)
    # A state mismatch must show the FAILURE page, not "Screenote connected"
    # — the page is chosen after validation, not before.
    response = raw_get(server, "/callback?code=code-123&state=wrong")
    err = assert_raises(Hive::Error) { waiter.value }
    assert_match(/state mismatch/, err.message)
    assert_includes response, "Screenote connection failed"
    refute_includes response, "Screenote connected"

    server = Hive::Screenote::LoopbackServer.new
    waiter = wait_for(server)
    response = raw_get(server, "/callback?state=state-123")
    err = assert_raises(Hive::Error) { waiter.value }
    assert_match(/did not include a code/, err.message)
    assert_includes response, "Screenote connection failed"
  end

  def test_wait_for_callback_times_out
    server = Hive::Screenote::LoopbackServer.new(timeout_sec: 0.01)

    err = assert_raises(Hive::Error) { server.wait_for_callback(expected_state: "state-123") }

    assert_match(/timed out/, err.message)
  end

  def test_read_callback_times_out_on_a_stalled_partial_request
    server = Hive::Screenote::LoopbackServer.new(read_timeout_sec: 0.05)
    waiter = wait_for(server)
    socket = TCPSocket.new(server.host, server.port)
    # Send a request line + one header but NEVER the terminating blank line,
    # and keep the socket open so the header read loop blocks.
    socket.write("GET /callback?code=c&state=state-123 HTTP/1.1\r\nHost: #{server.host}\r\n")

    err = assert_raises(Hive::Error) { waiter.value }
    assert_match(/timed out reading/, err.message)
  ensure
    socket&.close
  end

  private

  def raw_get(server, path)
    socket = TCPSocket.new(server.host, server.port)
    socket.write("GET #{path} HTTP/1.1\r\nHost: #{server.host}\r\nConnection: close\r\n\r\n")
    socket.read
  ensure
    socket&.close
  end

  def wait_for(server)
    Thread.new do
      Thread.current.report_on_exception = false
      server.wait_for_callback(expected_state: "state-123")
    end
  end

  def assert_port_released(port)
    rebound = TCPServer.new("127.0.0.1", port)
    rebound.close
  end
end
