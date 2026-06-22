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

  def test_wait_for_callback_ignores_non_callback_prefetch_and_keeps_waiting
    # A browser/OS prefetch of `/favicon.ico` must NOT consume the one-shot
    # accept and surface as a bogus state mismatch — the server answers 404
    # and keeps waiting for the real `/callback` redirect.
    server = Hive::Screenote::LoopbackServer.new
    waiter = wait_for(server)

    prefetch = raw_get(server, "/favicon.ico")
    assert_includes prefetch, "404 Not Found"
    refute_includes prefetch, "Screenote connected"

    response = raw_get(server, "/callback?code=code-123&state=state-123")
    result = waiter.value

    assert_equal({ "code" => "code-123", "state" => "state-123" }, result)
    assert_includes response, "Screenote connected"
  end

  def test_wait_for_callback_ignores_an_empty_first_request_line_and_keeps_waiting
    # An empty/EOF first request line (a bare connect-then-close) must 404 and
    # keep waiting, not consume the one real redirect.
    server = Hive::Screenote::LoopbackServer.new
    waiter = wait_for(server)

    TCPSocket.new(server.host, server.port).close

    response = raw_get(server, "/callback?code=code-123&state=state-123")
    result = waiter.value

    assert_equal({ "code" => "code-123", "state" => "state-123" }, result)
    assert_includes response, "Screenote connected"
  end

  def test_wait_for_callback_tolerates_a_malformed_request_target_and_keeps_waiting
    # A junk local request with an invalid percent-escape raises
    # URI::InvalidURIError inside read_callback_request — neither Hive::Error
    # nor SystemCallError — which used to escape connect as a raw backtrace.
    # It must 404 and keep waiting for the real redirect instead.
    server = Hive::Screenote::LoopbackServer.new
    waiter = wait_for(server)

    malformed = raw_get(server, "/callback?code=%ZZ&state=state-123")
    assert_includes malformed, "404 Not Found"
    refute_includes malformed, "Screenote connected"

    response = raw_get(server, "/callback?code=code-123&state=state-123")
    result = waiter.value

    assert_equal({ "code" => "code-123", "state" => "state-123" }, result)
    assert_includes response, "Screenote connected"
  end

  def test_wait_for_callback_rejects_oversized_request_headers
    server = Hive::Screenote::LoopbackServer.new
    waiter = wait_for(server)
    socket = TCPSocket.new(server.host, server.port)
    socket.write("GET /callback?code=c&state=state-123 HTTP/1.1\r\n")
    begin
      # > 64 KiB of header lines, each terminated but never the blank line
      # that ends the header read, so the cumulative cap fires.
      socket.write("X-Pad: #{"a" * 200}\r\n" * 400)
    rescue Errno::EPIPE, Errno::ECONNRESET
      # The server hit the cap and closed mid-write — expected.
    end

    err = assert_raises(Hive::Error) { waiter.value }
    assert_match(/exceeded .* bytes/, err.message)
  ensure
    socket&.close
  end

  def test_write_response_swallows_a_broken_socket_write
    # The success/failure page write is cosmetic; an EPIPE from a closed
    # browser tab must be swallowed (and warned) so it cannot pre-empt the
    # pending real `raise Hive::Error` in wait_for_callback.
    server = Hive::Screenote::LoopbackServer.new(timeout_sec: 0.01)
    broken = Object.new
    broken.define_singleton_method(:write) { |_payload| raise Errno::EPIPE, "broken pipe" }

    _out, err = capture_io do
      server.send(:write_response, broken, "page")
    end

    assert_match(/could not write Screenote loopback response page/, err)
  ensure
    server&.close
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
