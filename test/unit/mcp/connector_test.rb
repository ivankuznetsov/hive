require "test_helper"
require "json"
require "stringio"
require "hive/cli"
require "hive/commands/mcp"
require "hive/mcp/server"
require "hive/mcp/dispatcher"
require "hive/mcp/backend"
require "hive/commands/status"
require "hive/commands/act"
require "hive/commands/doctor"
require "hive/commands/answer"
require "hive/commands/task"
require "hive/config"

class McpConnectorTest < Minitest::Test
  include HiveTestHelper

  def test_initialize_negotiates_a_supported_protocol_version
    replies = session([
      request("initialize", { "protocolVersion" => "2025-03-26", "capabilities" => {} })
    ])

    result = replies.fetch(0).fetch("result")
    assert_equal "2025-03-26", result.fetch("protocolVersion")
    assert_equal "hive", result.dig("serverInfo", "name")
    assert_equal Hive::VERSION, result.dig("serverInfo", "version")
    assert_includes result.fetch("instructions"), "workflow.advance"
  end

  def test_unknown_protocol_version_falls_back_to_the_newest_supported
    replies = session([
      request("initialize", { "protocolVersion" => "1999-01-01" })
    ])

    assert_equal "2025-06-18", replies.fetch(0).dig("result", "protocolVersion")
  end

  def test_notifications_produce_no_response_and_tools_list_is_closed
    replies = session([
      { "jsonrpc" => "2.0", "method" => "notifications/initialized" },
      request("tools/list")
    ], dispatcher: Hive::Mcp::Dispatcher.new(backend: FakeBackend.new))

    assert_equal 1, replies.length
    names = replies.fetch(0).dig("result", "tools").map { |tool| tool.fetch("name") }
    assert_equal %w[status task doctor answer_inventory answer_write act], names
    replies.fetch(0).dig("result", "tools").each do |tool|
      assert_equal false, tool.dig("inputSchema", "additionalProperties")
    end
  end

  def test_tools_call_returns_text_and_rejects_bad_arguments
    replies = session([
      request("tools/call", { "name" => "status", "arguments" => {} }, id: 2),
      request("tools/call", { "name" => "act", "arguments" => { "bad" => true } }, id: 3),
      request("resources/list", {}, id: 4),
      { "jsonrpc" => "2.0", "id" => 5, "method" => "tools/call" }
    ], dispatcher: Hive::Mcp::Dispatcher.new(backend: FakeBackend.new))

    assert_equal "snapshot", replies.fetch(0).dig("result", "content", 0, "text")
    assert_equal false, replies.fetch(0).dig("result", "isError")
    assert_equal(-32_602, replies.fetch(1).dig("error", "code"))
    assert_equal(-32_601, replies.fetch(2).dig("error", "code"))
    assert_equal(-32_602, replies.fetch(3).dig("error", "code"))
  end

  def test_parse_errors_stay_on_the_rpc_stream
    input = StringIO.new("not-json\n")
    output = StringIO.new
    Hive::Mcp::Server.new(input: input, output: output, dispatcher: FakeBackend.new).run

    reply = JSON.parse(output.string)
    assert_equal(-32_700, reply.dig("error", "code"))
    assert_nil reply.fetch("id")
  end

  def test_act_requires_a_fresh_routine_descriptor
    backend = FakeBackend.new
    dispatcher = Hive::Mcp::Dispatcher.new(backend: backend)
    token = "a" * 64

    assert_raises(Hive::Mcp::Dispatcher::InvalidArguments) do
      dispatcher.call("act", {
        "action_id" => "workflow.close_with_evidence",
        "target" => "demo:task",
        "observation" => token
      })
    end
    assert_raises(Hive::Mcp::Dispatcher::InvalidArguments) do
      dispatcher.call("act", {
        "action_id" => "workflow.advance",
        "target" => "demo/task",
        "observation" => token
      })
    end
    assert_raises(Hive::Mcp::Dispatcher::InvalidArguments) do
      dispatcher.call("status", { "project" => "demo" })
    end

    result = dispatcher.call("act", {
      "action_id" => "workflow.retry",
      "target" => "demo:task",
      "observation" => token
    })
    assert_equal({ text: "acted", is_error: false }, result)
    assert_equal [ "act", {
      "action_id" => "workflow.retry", "target" => "demo:task", "observation" => token
    } ], backend.calls.last
  end

  def test_backend_status_and_act_use_the_json_command_contracts
    status = RecordingCommand.new('{"schema":"hive-operational-status","ok":true}')
    act = RecordingCommand.new('{"schema":"hive-act","ok":true}')
    with_replaced_singleton_method(Hive::Commands::Status, :new, ->(**kwargs) {
      status.kwargs = kwargs
      status
    }) do
      with_replaced_singleton_method(Hive::Commands::Act, :new, ->(*args, **kwargs) {
        act.args = args
        act.kwargs = kwargs
        act
      }) do
        backend = Hive::Mcp::Backend.new
        assert_equal false, backend.status({}).fetch(:is_error)
        token = "b" * 64
        assert_equal false, backend.act(
          "action_id" => "workflow.advance", "target" => "demo:task", "observation" => token
        ).fetch(:is_error)
      end
    end

    assert_equal({ json: true, operational: true }, status.kwargs)
    assert_equal [ "workflow.advance", "demo:task" ], act.args
    assert_equal({ observation: "b" * 64, json: true }, act.kwargs)
  end

  def test_backend_marks_a_failed_envelope_as_a_tool_error
    status = RecordingCommand.new('{"schema":"hive-operational-status","ok":false,"message":"no"}')
    with_replaced_singleton_method(Hive::Commands::Status, :new, ->(**) { status }) do
      result = Hive::Mcp::Backend.new.status({})
      assert_equal true, result.fetch(:is_error)
      assert_includes result.fetch(:text), '"ok":false'
    end
  end

  def test_backend_doctor_and_answer_write_stay_in_process
    doctor = RecordingDoctor.new
    answer = RecordingAnswer.new
    with_replaced_singleton_method(Hive::Config, :load, ->(*) { { "loaded" => true } }) do
      with_replaced_singleton_method(Hive::Commands::Doctor, :new, ->(**kwargs) {
        doctor.kwargs = kwargs
        doctor
      }) do
        with_replaced_singleton_method(Hive::Commands::Answer, :new, ->(*args, **kwargs) {
          answer.args = args
          answer.kwargs = kwargs
          answer
        }) do
          backend = Hive::Mcp::Backend.new
          health = backend.doctor({})
          written = backend.answer_write(
            "target" => "idea", "project" => "demo", "binding" => "bind", "answer" => "yes"
          )
          assert_equal false, health.fetch(:is_error)
          assert_includes health.fetch(:text), "hive-doctor.v2"
          assert_equal false, written.fetch(:is_error)
        end
      end
    end

    assert_equal true, doctor.kwargs.fetch(:json)
    assert_equal Dir.pwd, doctor.kwargs.fetch(:project_root)
    assert_equal [ "idea" ], answer.args
    assert_equal "bind", answer.kwargs.fetch(:binding)
    assert_equal "yes", answer.kwargs.fetch(:input).read
    assert_equal true, answer.kwargs.fetch(:json)
  end

  def test_task_log_is_forwarded_without_json
    task = RecordingCommand.new("log tail\n")
    with_replaced_singleton_method(Hive::Commands::Task, :new, ->(*args, **kwargs) {
      task.args = args
      task.kwargs = kwargs
      task
    }) do
      result = Hive::Mcp::Backend.new.task("target" => "idea", "log" => true)
      assert_equal "log tail", result.fetch(:text)
      assert_equal false, result.fetch(:is_error)
    end

    assert_equal [ "idea" ], task.args
    assert_equal({ project: nil, json: false, log: true }, task.kwargs)
  end

  def test_plugin_manifest_matches_the_hive_version_and_command
    root = Hive::Commands::Mcp.plugin_path
    plugin = JSON.parse(File.read(File.join(root, "plugin.json")))
    mcp = JSON.parse(File.read(File.join(root, ".mcp.json")))
    skill = File.read(File.join(root, "skills", "hive", "SKILL.md"))

    assert_equal Hive::VERSION, plugin.fetch("version")
    assert_equal [ "hive", "mcp" ], [ mcp.dig("mcpServers", "hive", "command"), *mcp.dig("mcpServers", "hive", "args") ]
    assert_includes skill, "hive digest --json"
    assert File.file?(File.join(root, "skills", "hive", "SKILL.md"))
  end

  def test_cli_prints_the_plugin_path_and_serves_without_it
    out, _err = capture_io { Hive::CLI.start([ "mcp", "--plugin-path" ]) }
    assert_equal "#{Hive::Commands::Mcp.plugin_path}\n", out

    calls = []
    server = Object.new
    server.define_singleton_method(:call) { calls << :served }
    with_replaced_singleton_method(Hive::Commands::Mcp, :new, ->(**kwargs) {
      calls << kwargs
      server
    }) do
      Hive::CLI.start([ "mcp" ])
    end

    assert_equal [ {}, :served ], calls
  end

  private

  def request(method, params = {}, id: 1)
    { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
  end

  def session(messages, dispatcher: FakeDispatcher.new)
    input = StringIO.new(messages.map { |message| JSON.generate(message) }.join("\n") + "\n")
    output = StringIO.new
    Hive::Mcp::Server.new(input: input, output: output, dispatcher: dispatcher).run
    output.string.split("\n").reject(&:empty?).map { |line| JSON.parse(line) }
  end

  class FakeDispatcher
    def catalog
      [ { "name" => "status", "inputSchema" => { "additionalProperties" => false } } ]
    end

    def call(_name, _arguments)
      { text: "hello", is_error: false }
    end
  end

  class FakeBackend
    attr_reader :calls

    def initialize
      @calls = []
    end

    def status(arguments)
      @calls << [ "status", arguments ]
      { text: "snapshot", is_error: false }
    end

    def act(arguments)
      @calls << [ "act", arguments ]
      { text: "acted", is_error: false }
    end
  end

  class RecordingCommand
    attr_accessor :args, :kwargs

    def initialize(body)
      @body = body
    end

    def call
      puts @body
    end
  end

  class RecordingDoctor
    attr_accessor :kwargs

    def call
      kwargs.fetch(:output).puts('{"schema":"hive-doctor.v2"}')
      0
    end
  end

  class RecordingAnswer
    attr_accessor :args, :kwargs

    def call
      kwargs.fetch(:output).puts('{"schema":"hive-answer","ok":true}')
      {}
    end
  end
end
