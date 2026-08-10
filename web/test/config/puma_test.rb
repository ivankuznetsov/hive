require "test_helper"
require "puma"
require "puma/configuration"
require "puma/server"
require "socket"

class PumaTest < ActiveSupport::TestCase
  test "oversized bodies receive 413 before the Rack app runs" do
    config = puma_configuration
    limit = Hive::Web::RequestLimits::MAX_BODY_BYTES
    assert_equal limit, config.options[:http_content_length_limit]

    calls = Queue.new
    server, listener = start_server(config, calls)

    socket = TCPSocket.new("127.0.0.1", listener.local_address.ip_port)
    socket.write("POST /ideas HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                 "Content-Length: #{limit + 1}\r\nConnection: close\r\n\r\nx")
    socket.write("y") unless IO.select([ socket ], nil, nil, 0.1)
    response = Timeout.timeout(5) { socket.readpartial(4096) }

    assert_match(%r{\AHTTP/1\.1 413\b}, response)
    assert calls.empty?, "Puma must reject the envelope before handing it to Rack"
  ensure
    socket&.close
    server&.stop(true)
  end

  test "chunked bodies receive 413 at the header boundary" do
    config = puma_configuration
    assert Puma::Client < Hive::Web::PumaRequestLimits::RejectChunkedBodies

    calls = Queue.new
    server, listener = start_server(config, calls)
    socket = TCPSocket.new("127.0.0.1", listener.local_address.ip_port)
    socket.write("POST /ideas HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                 "Transfer-Encoding: chunked\r\n\r\n")
    response = Timeout.timeout(5) { socket.read }

    assert_match(%r{\AHTTP/1\.1 413\b}, response)
    assert_includes response, "\r\nconnection: close\r\n"
    assert calls.empty?, "Puma must not stream a chunked body into a tempfile or Rack"
  ensure
    socket&.close
    server&.stop(true)
  end

  test "bounded bodies still reach the Rack app" do
    config = puma_configuration
    calls = Queue.new
    server, listener = start_server(config, calls)
    socket = TCPSocket.new("127.0.0.1", listener.local_address.ip_port)
    socket.write("POST /ideas HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                 "Content-Length: 1\r\nConnection: close\r\n\r\nx")
    response = Timeout.timeout(5) { socket.readpartial(4096) }

    assert_match(%r{\AHTTP/1\.1 200\b}, response)
    assert Timeout.timeout(5) { calls.pop }
  ensure
    socket&.close
    server&.stop(true)
  end

  private

  def puma_configuration
    Puma::Configuration.new(config_files: [ Rails.root.join("config/puma.rb").to_s ]).tap do |config|
      config.load
      config.clamp
    end
  end

  def start_server(config, calls)
    app = lambda do |_env|
      calls << true
      [ 200, { "content-type" => "text/plain" }, [ "unexpected" ] ]
    end
    server = Puma::Server.new(app, nil, config.options)
    listener = server.add_tcp_listener("127.0.0.1", 0)
    server.run
    [ server, listener ]
  end
end
