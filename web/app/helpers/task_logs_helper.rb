require "json"

module TaskLogsHelper
  # Only display message text and tool names. Provider envelopes can contain
  # prompts, credentials, tool inputs and reasoning that are not log messages.
  def task_log_entries(tail)
    tail.to_s.each_line.flat_map do |line|
      text = line.strip
      next [] if text.empty?

      timestamp = nil
      if (match = text.match(/\A\[(?:stream|hive|stdout|stderr)\]\s+(\d{4}-\S+)\s+(.*)\z/))
        timestamp, text = match.captures
      end
      # The durable writer intentionally withholds structured message payloads.
      # This is successful redaction, not a corrupt or incomplete log entry.
      next [] if text.match?(/\A\[(?:structured message|opencode event) omitted type=[^\]]+\]\z/)

      entries = if text.start_with?("{", "[")
        begin
          task_log_event_entries(JSON.parse(text))
        rescue JSON::ParserError
          [ { kind: "activity", label: "Log", text: "Incomplete log entry — this message could not be read." } ]
        end
      else
        [ { kind: text.match?(/\b(error|failed|fatal)\b/i) ? "errors" : "activity", label: "Output", text: text } ]
      end
      entries.each { |entry| entry[:time] = timestamp&.split("T")&.last&.delete_suffix("Z") }
    end
  end

  private

  def task_log_event_entries(event)
    return [] unless event.is_a?(Hash)

    case event["type"]
    when "assistant"
      message = event["message"]
      return [] unless message.is_a?(Hash)
      task_log_content_entries(message["content"])
    when "agent_message"
      task_log_message_entries(event)
    when "item.completed", "item.started"
      item = event["item"]
      return [] unless item.is_a?(Hash)
      case item["type"]
      when "agent_message", "message"
        event["type"] == "item.completed" ? task_log_message_entries(item) : []
      when "command_execution"
        failed = item["exit_code"].is_a?(Numeric) && item["exit_code"] != 0
        [ { kind: failed ? "errors" : "tools", label: "Command", text: failed ? "Command failed (exit #{item['exit_code']})." : (event["type"] == "item.started" ? "Running a command." : "Command finished.") } ]
      else
        []
      end
    when "result"
      task_log_text_entry(event["result"], kind: event["is_error"] == true ? "errors" : "messages", label: "Result")
    when "text"
      task_log_text_entry(event["data"], kind: "messages", label: "Agent")
    when "error", "turn.failed"
      error = event["error"]
      message = event["message"] || (error.is_a?(Hash) ? error["message"] : error)
      task_log_text_entry(message.is_a?(String) ? message : "The agent reported an error.", kind: "errors", label: "Error")
    else
      []
    end
  end

  def task_log_message_entries(message)
    text = message["text"] || message["message"]
    text.is_a?(String) ? task_log_text_entry(text, kind: "messages", label: "Agent") : task_log_content_entries(message["content"])
  end

  def task_log_content_entries(content)
    return task_log_text_entry(content, kind: "messages", label: "Agent") if content.is_a?(String)
    return [] unless content.is_a?(Array)

    content.flat_map do |block|
      next [] unless block.is_a?(Hash)
      case block["type"]
      when "text", "output_text"
        task_log_text_entry(block["text"], kind: "messages", label: "Agent")
      when "tool_use"
        name = block["name"]
        [ { kind: "tools", label: "Tool", text: name.is_a?(String) ? "Using #{name}." : "Using a tool." } ]
      else
        []
      end
    end
  end

  def task_log_text_entry(text, kind:, label:)
    return [] unless text.is_a?(String) && text.present?
    [ { kind: kind, label: label, text: text } ]
  end
end
