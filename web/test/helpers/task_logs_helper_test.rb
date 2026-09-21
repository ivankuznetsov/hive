require "test_helper"

class TaskLogsHelperTest < ActionView::TestCase
  include TaskLogsHelper

  test "Claude text and tool names exclude envelope fields and thinking" do
    line = JSON.generate(type: "assistant", session_id: "hidden-session", message: {
      content: [
        { type: "text", text: "Fixing the failing test." },
        { type: "thinking", thinking: "hidden-reasoning" },
        { type: "tool_use", name: "Read", input: { secret: "hidden-secret" } }
      ]
    })
    entries = task_log_entries("[stream] 2026-09-04T10:30:00Z #{line}\n")
    assert_equal [ "messages", "tools" ], entries.pluck(:kind)
    assert_equal [ "Fixing the failing test.", "Using Read." ], entries.pluck(:text)
    assert_equal "10:30:00", entries.first[:time]
    refute_match(/hidden/, entries.inspect)
  end

  test "Codex failures show exit status without commands or tool output" do
    records = [
      { type: "item.completed", item: { type: "agent_message", text: "Tests passed." } },
      { type: "item.completed", item: { type: "command_execution", exit_code: 1, command: "hidden-command", aggregated_output: "hidden-output" } },
      { type: "turn.failed", error: { message: "Provider unavailable", token: "hidden-token" } }
    ]
    entries = task_log_entries(records.map(&:to_json).join("\n"))
    assert_equal [ "messages", "errors", "errors" ], entries.pluck(:kind)
    assert_equal [ "Tests passed.", "Command failed (exit 1).", "Provider unavailable" ], entries.pluck(:text)
    refute_match(/hidden/, entries.inspect)
  end

  test "plaintext is readable and incomplete JSON never dumps partial payloads" do
    entries = task_log_entries("plain output\n{\"api_key\":\"hidden-secret\"\n[]\n")
    assert_equal "plain output", entries.first[:text]
    assert_match(/Incomplete log entry/, entries.second[:text])
    refute_match(/hidden-secret/, entries.inspect)
  end

  test "provider metadata and malformed message shapes are omitted" do
    records = [
      { type: "system", api_key: "hidden-key" },
      { type: "assistant", message: [ "hidden-value" ] },
      { type: "assistant", message: { content: [ nil, "hidden-value" ] } },
      { type: "result", result: { secret: "hidden-value" } },
      { type: "item.completed", item: "hidden-value" }
    ]
    assert_empty task_log_entries(records.map(&:to_json).join("\n"))
  end

  test "result errors and alternate Codex messages receive useful categories" do
    records = [
      { type: "result", is_error: true, result: "Rate limit reached" },
      { type: "item.completed", item: { type: "message", content: [ { type: "output_text", text: "Ready for review" } ] } }
    ]
    entries = task_log_entries(records.map(&:to_json).join("\n"))
    assert_equal [ "errors", "messages" ], entries.pluck(:kind)
    assert_equal [ "Rate limit reached", "Ready for review" ], entries.pluck(:text)
  end

  test "durable structured message omission is not reported as a broken log" do
    tail = "[stream] 2026-09-04T10:30:00Z [structured message omitted type=assistant]\n[opencode event omitted type=text]\nplain output\n"
    assert_equal [ "plain output" ], task_log_entries(tail).pluck(:text)
  end

  test "view escapes HTML and keeps tail follow hook and filters" do
    render partial: "tasks/log", locals: {
      project: Struct.new(:name).new("demo"), task: Struct.new(:slug).new("task"), reference_sha256: "digest",
      log: { "path" => "/private/log.jsonl", "tail" => { type: "result", result: '<script>alert("x")</script>' }.to_json }
    }
    assert_select "pre[data-tail-follow] .task-log-message", text: '<script>alert("x")</script>'
    assert_select "script", count: 0
    assert_select "select option", count: 4
    assert_select "input[type=search]"
    refute_includes rendered, "/private/log.jsonl"
  end
end
