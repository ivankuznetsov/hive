require "fileutils"
require "json"
require "securerandom"
require "time"

module Hive
  module Events
    EVENT_TYPES = %i[
      stage_enter
      stage_exit
      agent_start
      agent_end
      error
      round_waiting
      round_complete
    ].freeze

    STATUS_TAIL_LINES = 20

    module_function

    # Append-only event log for task-local lifecycle observability.
    #
    # Each emit performs one O_APPEND write of a short JSON line. POSIX
    # guarantees atomic append positioning for this form; keep records small
    # and single-write so concurrent emitters cannot interleave bytes within a
    # line. status.md is derived state and is rewritten with atomic rename.
    def emit(task_folder:, slug:, stage:, event_type:, agent: nil, message: nil)
      event_type = event_type.to_sym
      unless EVENT_TYPES.include?(event_type)
        raise ArgumentError, "unknown event_type #{event_type.inspect}; valid: #{EVENT_TYPES.inspect}"
      end

      record = {
        "ts" => Time.now.utc.iso8601,
        "slug" => slug.to_s,
        "stage" => stage.to_s,
        "agent" => agent.nil? ? nil : agent.to_s,
        "event_type" => event_type.to_s,
        "message" => message.nil? ? nil : message.to_s
      }

      FileUtils.mkdir_p(task_folder)
      events_path = File.join(task_folder, "events.jsonl")
      File.open(events_path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") do |file|
        file.write(JSON.generate(record))
        file.write("\n")
      end
      render_status!(task_folder, record)
      record
    rescue SystemCallError => e
      warn "[hive.events] failed to emit #{event_type} for #{task_folder}: #{e.class}: #{e.message}"
      nil
    end

    def render_status!(task_folder, last_record)
      events = read_recent_events(File.join(task_folder, "events.jsonl"), STATUS_TAIL_LINES)
      body = render_status_body(last_record, events)
      write_atomic(File.join(task_folder, "status.md"), body)
    end

    def render_status_body(last_record, events)
      current_agent = current_agent(events)
      last_message = last_record["message"].to_s.empty? ? "-" : last_record["message"].to_s
      lines = [
        "# Status: #{last_record.fetch('slug')}",
        "Stage:        #{last_record.fetch('stage')}",
        "Updated:      #{last_record.fetch('ts')}",
        "Last event:   #{last_record.fetch('event_type')} - #{last_message}",
        "Current agent: #{current_agent || '-'}",
        "",
        "## Recent events (last #{STATUS_TAIL_LINES})"
      ]
      if events.empty?
        lines << "- (no events yet)"
      else
        events.each do |event|
          agent = event["agent"].to_s.empty? ? "-" : event["agent"].to_s
          message = event["message"].to_s.empty? ? "-" : event["message"].to_s
          lines << "- #{event['ts']}  #{event['event_type']}  #{agent}  #{message}"
        end
      end
      "#{lines.join("\n")}\n"
    end

    def current_agent(events)
      open_agents = []
      events.each do |event|
        agent = event["agent"].to_s
        next if agent.empty?

        case event["event_type"]
        when "agent_start"
          open_agents.delete(agent)
          open_agents << agent
        when "agent_end"
          open_agents.delete(agent)
        end
      end
      open_agents.last
    end

    def read_recent_events(path, limit)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).last(limit).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end

    def write_atomic(path, body)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(
        dir,
        ".#{File.basename(path)}.tmp.#{Process.pid}.#{Thread.current.object_id}.#{SecureRandom.hex(4)}"
      )
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o644, encoding: "UTF-8") do |file|
        file.write(body)
        file.flush
        begin
          file.fsync
        rescue StandardError
          nil
        end
      end
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end
end
