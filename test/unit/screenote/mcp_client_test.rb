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

  def test_list_projects_returns_empty_for_missing_or_unparseable_text_content
    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => { "content" => [ { "text" => "plain" } ] })))
    )
    assert_equal [], client.list_projects

    client = Hive::Screenote::McpClient.new(
      resource: "https://screenote.test/mcp",
      access_token: "token",
      http: FakeHttp.new(self.class.ok(JSON.generate("result" => { "content" => [ { "text" => "{" } ] })))
    )
    assert_equal [], client.list_projects
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
