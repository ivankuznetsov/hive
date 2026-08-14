require "test_helper"
require "hive/artifacts/capture_proxy"

class ArtifactsCaptureProxyCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Proxy = Hive::Artifacts::CaptureProxy

  def test_initialization_and_close_normalize_invalid_ports_and_os_failures
    assert_raises(Proxy::ProxyError) { Proxy.new(app_port: 0) }
    assert_raises(Proxy::ProxyError) { Proxy.new(app_port: "not-a-port") }

    calls = 0
    error = with_replaced_singleton_method(TCPServer, :new, lambda do |*|
      calls += 1
      raise Errno::EACCES, "denied" if calls == 1
    end) do
      assert_raises(Proxy::ProxyError) { Proxy.new(app_port: 1234) }
    end
    assert_match(/unavailable/, error.message)

    proxy = Proxy.allocate
    proxy.instance_variable_set(:@mutex, Mutex.new)
    proxy.instance_variable_set(:@server, Object.new.tap do |server|
      server.define_singleton_method(:closed?) { false }
      server.define_singleton_method(:close) { raise IOError, "closed" }
    end)
    proxy.instance_variable_set(:@clients, [])
    proxy.instance_variable_set(:@client_threads, [])
    refute proxy.close
  end

  def test_reserve_port_closes_the_temporary_server
    proxy = Proxy.allocate
    closed = false
    server = Object.new
    address = Struct.new(:ip_port).new(42_424)
    server.define_singleton_method(:local_address) { address }
    server.define_singleton_method(:close) { closed = true }

    value = with_replaced_singleton_method(TCPServer, :new, ->(*) { server }) do
      proxy.send(:reserve_port)
    end
    assert_equal 42_424, value
    assert closed
  end

  def test_accept_loop_retries_and_rejects_when_capacity_is_exhausted
    proxy = Proxy.allocate
    proxy.instance_variable_set(:@closed, false)
    proxy.instance_variable_set(:@mutex, Mutex.new)
    proxy.instance_variable_set(:@clients, [])
    alive = Array.new(Proxy::MAX_CONNECTIONS) do
      Object.new.tap { |thread| thread.define_singleton_method(:alive?) { true } }
    end
    proxy.instance_variable_set(:@client_threads, alive)
    calls = 0
    client = fake_client
    server = Object.new
    server.define_singleton_method(:accept) do
      calls += 1
      raise Errno::ECONNABORTED if calls == 1
      return client if calls == 2

      raise IOError, "closed"
    end
    proxy.instance_variable_set(:@server, server)

    assert_nil proxy.send(:accept_connections)
    assert client.closed?
    assert_includes client.writes.join, "503 Service Unavailable"

    closed_proxy = Proxy.allocate
    closed_proxy.instance_variable_set(:@closed, true)
    closed_proxy.instance_variable_set(:@mutex, Mutex.new)
    closed_proxy.instance_variable_set(:@clients, [])
    closed_proxy.instance_variable_set(:@client_threads, [])
    closed_client = fake_client
    closed_server = Object.new
    closed_server.define_singleton_method(:accept) { closed_client }
    closed_proxy.instance_variable_set(:@server, closed_server)
    assert_nil closed_proxy.send(:accept_connections)
    assert closed_client.closed?
  end

  def test_request_errors_are_mapped_without_leaking_upstream_authority
    proxy = Proxy.new
    invalid = raw_request(proxy, "GET http://%zz HTTP/1.1\r\n\r\n")
    assert_includes invalid, "400 Bad Request"

    unavailable = raw_request(
      proxy,
      "GET #{proxy.origin}/missing HTTP/1.1\r\nHost: ignored\r\n\r\n"
    )
    assert_includes unavailable, "502 Bad Gateway"
  ensure
    proxy&.close
  end

  def test_header_reader_rejects_timeout_oversize_and_incomplete_requests
    proxy = Proxy.allocate
    timeout_client = fake_client
    times = [ 0.0, Proxy::READ_TIMEOUT_SECONDS + 1.0 ]
    with_replaced_singleton_method(
      Process, :clock_gettime, ->(*) { times.shift || times.last }
    ) do
      assert_raises(Proxy::ProxyError) { proxy.send(:read_header, timeout_client) }
    end

    oversized = fake_client
    oversized.define_singleton_method(:read_nonblock) do |amount|
      "x" * amount
    end
    with_replaced_singleton_method(IO, :select, ->(*) { [ [ oversized ] ] }) do
      assert_raises(Proxy::ProxyError) { proxy.send(:read_header, oversized) }
    end

    incomplete = fake_client
    incomplete.define_singleton_method(:read_nonblock) { |_| raise EOFError }
    with_replaced_singleton_method(IO, :select, ->(*) { [ [ incomplete ] ] }) do
      assert_raises(Proxy::ProxyError) { proxy.send(:read_header, incomplete) }
    end
  end

  def test_relay_waits_for_readability_and_reject_swallows_disconnects
    proxy = Proxy.allocate
    client = fake_client
    upstream = fake_client
    selections = [ [ [ client ] ], nil ]
    client.define_singleton_method(:read_nonblock) { |*, **| :wait_readable }
    with_replaced_singleton_method(IO, :select, ->(*) { selections.shift }) do
      assert_nil proxy.send(:relay, client, upstream)
    end

    broken = Object.new
    broken.define_singleton_method(:write) { |_| raise Errno::EPIPE }
    assert_nil proxy.send(:reject, broken, "400 Bad Request")
  end

  private

  def fake_client
    writes = []
    closed = false
    Object.new.tap do |client|
      client.define_singleton_method(:write) { |value| writes << value }
      client.define_singleton_method(:close) { closed = true }
      client.define_singleton_method(:closed?) { closed }
      client.define_singleton_method(:writes) { writes }
    end
  end

  def raw_request(proxy, request)
    uri = URI(proxy.proxy_url)
    socket = TCPSocket.new(uri.host, uri.port)
    socket.write(request)
    socket.read
  ensure
    socket&.close
  end
end
