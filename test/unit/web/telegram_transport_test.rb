require "test_helper"
require "socket"
require "json"
require "hive/web/telegram_validator"
require "hive/web/telegram_tester"

# P1-7: the validator/tester set short Telegram timeouts and rescue transport
# failures (Faraday::TimeoutError / ConnectionFailed / SocketError), converting
# them to Hive::Error so the app's `error Hive::Error` handler renders a
# friendly "couldn't reach Telegram" page instead of an opaque ~20s blank 500.
#
# Nothing here stubs the telegram gem. Network-error cases point the gem's own
# `url:` option at an unroutable loopback port (real Faraday::ConnectionFailed);
# success / Bot-API-error cases point it at a tiny throwaway TCP server that
# returns canned Bot-API JSON, so the gem makes a genuine HTTP round-trip and
# parses a real response/error.
class WebTelegramTransportTest < Minitest::Test
  include HiveTestHelper

  # Connection refused: nothing listens on TCP port 1 of loopback.
  UNROUTABLE_URL = "http://127.0.0.1:1/".freeze

  def test_timeouts_are_clamped_to_a_short_window
    config = ::Telegram::Bot.configuration

    assert_equal 8, config.connection_open_timeout,
                 "the connect timeout must be clamped well under the gem's 20s default"
    assert_equal 8, config.connection_timeout,
                 "the read timeout must be clamped well under the gem's 20s default"
  end

  def test_validator_maps_a_network_failure_to_hive_error
    error = assert_raises(Hive::Error) do
      Hive::Web::TelegramValidator.call("123:tok", url: UNROUTABLE_URL)
    end

    assert_match(/couldn't reach Telegram/, error.message,
                 "a transport failure must surface a friendly Hive::Error, not an opaque 500")
  end

  def test_tester_maps_a_network_failure_to_hive_error
    error = assert_raises(Hive::Error) do
      Hive::Web::TelegramTester.call(token: "123:tok", chat_ids: [ "1" ], url: UNROUTABLE_URL)
    end

    assert_match(/couldn't reach Telegram/, error.message,
                 "a transport failure must surface a friendly Hive::Error, not an opaque 500")
  end

  def test_tester_still_short_circuits_when_no_chats_configured
    assert_equal({ ok: false, error: "no allowed chat IDs configured" },
                 Hive::Web::TelegramTester.call(token: "123:tok", chat_ids: []),
                 "an empty allowlist is reported before any network call")
  end

  def test_validator_accepts_a_token_the_api_confirms
    with_fake_telegram(getme: BOT_OK_USER) do |url|
      assert Hive::Web::TelegramValidator.call("123:good", url: url),
             "a getMe that returns a User must validate the token"
    end
  end

  def test_validator_rejects_a_token_the_api_401s
    with_fake_telegram(getme: UNAUTHORIZED) do |url|
      refute Hive::Web::TelegramValidator.call("123:bad", url: url),
             "a 401 (ResponseError) must reject the token, not raise"
    end
  end

  def test_tester_maps_a_getme_response_error_to_a_result_hash
    with_fake_telegram(getme: UNAUTHORIZED) do |url|
      result = Hive::Web::TelegramTester.call(token: "123:bad", chat_ids: [ "1" ], url: url)

      refute result[:ok], "a Bot-API ResponseError must surface as a non-raising failure result"
      assert result[:error], "the failure result must carry a message"
    end
  end

  def test_tester_round_trips_getme_then_send_message
    with_fake_telegram(getme: BOT_OK_USER, send_message: SENT_MESSAGE) do |url|
      result = Hive::Web::TelegramTester.call(token: "123:good", chat_ids: %w[1 2], url: url)

      assert_equal({ ok: true, sent: 2 }, result,
                   "a healthy getMe + sendMessage to every chat reports the count sent")
    end
  end

  private

  # Canned [http_status, json_body] responses, keyed to the Bot-API shapes.
  BOT_OK_USER = [ 200, { "ok" => true, "result" => { "id" => 1, "is_bot" => true, "first_name" => "B" } } ].freeze
  SENT_MESSAGE = [
    200, { "ok" => true, "result" => { "message_id" => 1, "date" => 0, "chat" => { "id" => 1, "type" => "private" } } }
  ].freeze
  UNAUTHORIZED = [ 401, { "ok" => false, "error_code" => 401, "description" => "Unauthorized" } ].freeze

  # Boot a throwaway single-threaded TCP server that speaks just enough HTTP to
  # answer the gem's POSTs to /bot<token>/getMe and /bot<token>/sendMessage,
  # returns the canned response for the matched endpoint, and yields its base
  # URL. Real sockets, real HTTP, real gem parsing — no gem stubbing.
  def with_fake_telegram(getme:, send_message: nil)
    server = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{server.addr[1]}"
    handler = Thread.new do
      loop do
        client = server.accept
        respond(client, getme: getme, send_message: send_message || getme)
      rescue IOError, Errno::EBADF
        break # server closed
      end
    end
    begin
      yield url
    ensure
      server.close
      handler.join
    end
  end

  def respond(client, getme:, send_message:)
    request_line = client.gets.to_s
    drain_headers_and_body(client)
    status, body = request_line.include?("/sendMessage") ? send_message : getme
    payload = JSON.generate(body)
    client.write(
      "HTTP/1.1 #{status} X\r\n" \
      "Content-Type: application/json\r\n" \
      "Content-Length: #{payload.bytesize}\r\n" \
      "Connection: close\r\n\r\n#{payload}"
    )
  ensure
    client.close
  end

  # Read headers, then consume exactly Content-Length bytes of the form body so
  # the socket is fully drained before we reply.
  def drain_headers_and_body(client)
    length = 0
    while (line = client.gets)
      break if line == "\r\n"

      length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)/i
    end
    client.read(length) if length.positive?
  end
end
