require "test_helper"
require "net/http"
require "hive/screenote/mcp_client"

class ScreenoteMcpClientTest < Minitest::Test
  class FakeHttp
    Recorded = Struct.new(:path, :body, :headers, :options)

    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def start(_host, _port, **options)
      @options = options
      yield self
    end

    def request(req)
      @requests << Recorded.new(req.path, req.body.to_s, req.to_hash, @options)
      @response.respond_to?(:call) ? @response.call(req) : @response
    end
  end

  class TimeoutHttp
    def start(*) = raise Net::ReadTimeout, "execution expired"
  end

  def self.response(klass, code, body)
    res = klass.new("1.1", code, "X")
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end

  def self.ok(body) = response(Net::HTTPOK, "200", body)

  def self.bad = response(Net::HTTPUnauthorized, "401", "")

  def test_list_projects_calls_mcp_tool_with_bearer_and_json_rpc
    http = FakeHttp.new(self.class.ok(JSON.generate("result" => { "projects" => [ { "id" => "proj_1" } ] })))
    client = Hive::Screenote::McpClient.new(resource: "https://screenote.test/mcp", access_token: "token", http: http)

    projects = client.list_projects

    assert_equal [ { "id" => "proj_1" } ], projects
    req = http.requests.first
    assert_equal "/mcp", req.path
    assert_equal "Bearer token", req.headers["authorization"].first
    body = JSON.parse(req.body)
    assert_equal "tools/call", body["method"]
    assert_equal "list_projects", body.dig("params", "name")
    assert_equal true, req.options[:use_ssl]
  end

  def test_list_projects_accepts_structured_content_and_text_payloads
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => {
        "structuredContent" => { "projects" => [ { "id" => "structured" } ] }
      })))
    )
    assert_equal [ { "id" => "structured" } ], client.list_projects

    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => {
        "content" => [ { "type" => "text", "text" => JSON.generate([ { "id" => "text-array" } ]) } ]
      })))
    )
    assert_equal [ { "id" => "text-array" } ], client.list_projects

    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => {
        "content" => [ { "type" => "text", "text" => JSON.generate("projects" => [ { "id" => "text-hash" } ]) } ]
      })))
    )
    assert_equal [ { "id" => "text-hash" } ], client.list_projects
  end

  def test_list_projects_returns_empty_for_non_jsonish_or_missing_content
    # text that does not LOOK like JSON ("plain") is a legitimately-empty
    # payload → []. structuredContent present but without a projects array
    # falls through to the content branch, which is absent → [].
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => { "content" => [ { "text" => "plain" } ] })))
    )
    assert_equal [], client.list_projects

    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => { "structuredContent" => { "count" => 0 } })))
    )
    assert_equal [], client.list_projects
  end

  def test_list_projects_raises_when_jsonish_text_payload_is_unparseable
    # A text payload that LOOKED like JSON (started with `{`) but does not
    # parse must raise — swallowing it to [] surfaced to the operator as
    # the benign "create a project and reconnect" message (wrong remedy).
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => { "content" => [ { "text" => "{" } ] })))
    )
    assert_match(/unparseable projects payload/,
                 assert_raises(Hive::Error) { client.list_projects }.message)
  end

  def test_call_tool_advertises_sse_accept_for_streamable_http
    http = FakeHttp.new(self.class.ok(JSON.generate("result" => { "projects" => [] })))
    client = Hive::Screenote::McpClient.new(resource: "https://screenote.test/mcp", access_token: "token", http: http)

    client.list_projects

    assert_equal "application/json, text/event-stream", http.requests.first.headers["accept"].first
  end

  def test_call_tool_raises_typed_error_on_mcp_tool_channel_iserror
    # A 2xx JSON-RPC reply whose `result` is `{"isError":true,...}` is a TOOL
    # failure (bad scope / rate-limit / 5xx). It must raise a typed Hive::Error
    # with the joined content text, not fall through to [] (list_projects) or
    # be read as a successful upload (create_screenshot_upload).
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => {
        "isError" => true,
        "content" => [ { "type" => "text", "text" => "rate limit exceeded (60/min)" } ]
      })))
    )
    err = assert_raises(Hive::Error) { client.list_projects }
    assert_match(/list_projects failed/, err.message)
    assert_match(/rate limit exceeded/, err.message)
  end

  def test_extract_projects_returns_empty_for_non_hash_result
    # A `{"result":[…]}` array result used to raise an untyped TypeError from
    # `result["projects"]`; the guard degrades it to the empty-projects path.
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => [ { "id" => "x" } ])))
    )
    assert_equal [], client.list_projects
  end

  def test_call_tool_parses_sse_framed_response
    # A spec-compliant Streamable-HTTP server may answer with an SSE body;
    # the `data:` payload must be de-framed and parsed, not failed as
    # "unparseable response".
    sse = "event: message\r\n" \
          "data: #{JSON.generate("result" => { "projects" => [ { "id" => "sse_proj" } ] })}\r\n\r\n"
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(sse))
    )
    assert_equal [ { "id" => "sse_proj" } ], client.list_projects
  end

  def test_call_tool_raises_on_a_string_json_rpc_error
    # A non-conformant server may send `"error":"<string>"` rather than an
    # object; guarding only on is_a?(Hash) let it skip the raise and fall
    # through to the misleading empty-projects remedy. Any truthy error is a
    # protocol failure.
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("error" => "method not found")))
    )
    err = assert_raises(Hive::Error) { client.list_projects }
    assert_match(/list_projects failed/, err.message)
    assert_match(/method not found/, err.message)
  end

  def test_list_projects_normalizes_the_project_id_key_to_a_canonical_id
    # Raw Screenote projects may key the id under "project_id"; the McpClient
    # seam normalizes it to a canonical "id" so connect/artifacts don't each
    # re-derive the fallback.
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => {
        "projects" => [ { "project_id" => "proj_alt", "name" => "Alt" } ]
      })))
    )
    assert_equal "proj_alt", client.list_projects.first["id"]
  end

  def test_call_tool_selects_the_result_event_among_interleaved_sse_events
    # A spec-compliant server may emit a non-JSON keep-alive and a notification
    # event BEFORE the JSON-RPC result on the same stream; blind-joining every
    # event's data payload would splice them into an unparseable body. The
    # result is selected by its JSON-RPC id (the first call's id is 1); a
    # non-JSON event and an id-less notification are skipped.
    keep_alive = "keep-alive"
    notif = JSON.generate("jsonrpc" => "2.0", "method" => "notifications/progress", "params" => {})
    result = JSON.generate("jsonrpc" => "2.0", "id" => 1, "result" => { "projects" => [ { "id" => "sse_real" } ] })
    sse = "event: ping\r\ndata: #{keep_alive}\r\n\r\n" \
          "event: message\r\ndata: #{notif}\r\n\r\n" \
          "event: message\r\ndata: #{result}\r\n\r\n"
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(sse))
    )
    assert_equal [ { "id" => "sse_real" } ], client.list_projects
  end

  def test_call_tool_forwards_arguments_and_increments_request_id
    http = FakeHttp.new(self.class.ok(JSON.generate("result" => {})))
    client = Hive::Screenote::McpClient.new(resource: "https://screenote.test/mcp", access_token: "token", http: http)

    client.call_tool("create_screenshot_upload", "project_id" => "proj_1", "title" => "Shot")
    client.call_tool("list_projects")

    first = JSON.parse(http.requests[0].body)
    second = JSON.parse(http.requests[1].body)
    assert_equal({ "project_id" => "proj_1", "title" => "Shot" }, first.dig("params", "arguments"))
    assert_equal 1, first["id"]
    assert_equal 2, second["id"]
  end

  def test_call_tool_create_screenshot_upload_round_trips_through_http_seam
    # Unit coverage for the upload tool's request/response contract through
    # the FakeHttp seam; the end-to-end live exercise stays in
    # test/integration/screenote_capture_live_test.rb (skip-blocked until
    # Screenote ships the non-interactive test-token endpoint).
    body = JSON.generate("result" => { "structuredContent" => {
      "upload_url" => "https://uploads.screenote.test/signed",
      "screenote_url" => "https://screenote.test/s/abc"
    } })
    http = FakeHttp.new(self.class.ok(body))
    client = Hive::Screenote::McpClient.new(resource: "https://screenote.test/mcp", access_token: "token", http: http)

    result = client.call_tool(
      "create_screenshot_upload",
      "project_id" => "proj_1", "filename" => "shot.png", "content_type" => "image/png"
    )

    assert_equal "https://uploads.screenote.test/signed", result.dig("structuredContent", "upload_url")
    req = JSON.parse(http.requests.first.body)
    assert_equal "create_screenshot_upload", req.dig("params", "name")
    assert_equal "proj_1", req.dig("params", "arguments", "project_id")
    assert_equal "image/png", req.dig("params", "arguments", "content_type")
  end

  def test_call_tool_surfaces_mcp_http_json_and_network_errors
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("error" => { "message" => "revoked" })))
    )
    assert_match(/revoked/, assert_raises(Hive::Error) { client.call_tool("list_projects") }.message)

    client = Hive::Screenote::McpClient.new(resource: "https://screenote.test/mcp", access_token: "token",
                                            http: FakeHttp.new(self.class.bad))
    assert_match(/HTTP 401/, assert_raises(Hive::Error) { client.call_tool("list_projects") }.message)

    client = Hive::Screenote::McpClient.new(resource: "https://screenote.test/mcp", access_token: "token",
                                            http: FakeHttp.new(self.class.ok("[")))
    assert_match(/unparseable/, assert_raises(Hive::Error) { client.call_tool("list_projects") }.message)

    client = Hive::Screenote::McpClient.new(resource: "https://screenote.test/mcp", access_token: "token",
                                            http: FakeHttp.new(self.class.ok("[]")))
    assert_match(/non-object/, assert_raises(Hive::Error) { client.call_tool("list_projects") }.message)

    client = Hive::Screenote::McpClient.new(resource: "https://screenote.test/mcp", access_token: "token",
                                            http: TimeoutHttp.new)
    assert_match(/could not reach Screenote/, assert_raises(Hive::Error) { client.call_tool("list_projects") }.message)
  end
end
