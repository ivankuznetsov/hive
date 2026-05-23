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
    # Width of the trailing window scanned to recover the "current agent"
    # line in status.md. Must comfortably exceed STATUS_TAIL_LINES so a
    # long-running agent whose agent_start scrolled past the recent-events
    # tail still renders honestly.
    CURRENT_AGENT_WALK_LINES = 200
    # Read this many trailing bytes when recovering recent events. Small
    # enough that emit cost stays sub-millisecond on a long log; large
    # enough that CURRENT_AGENT_WALK_LINES fits comfortably for our
    # ~140-char records (16 KiB ≈ 100 records minimum).
    STATUS_TAIL_BYTES = 16 * 1024

    EM_DASH = "—".freeze

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
      # Single-write append so POSIX append-atomicity for sub-PIPE_BUF
      # writes (~4 KiB) holds across concurrent emitters; the docstring's
      # "one O_APPEND write" guarantee would be void if we split the JSON
      # payload and the trailing newline into two writes.
      line = "#{JSON.generate(record)}\n"
      File.open(events_path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") do |file|
        file.write(line)
      end
      render_status!(task_folder, record)
      record
    rescue SystemCallError => e
      warn "[hive.events] failed to emit #{event_type} for #{task_folder}: #{e.class}: #{e.message}"
      nil
    end

    def render_status!(task_folder, last_record)
      events_path = File.join(task_folder, "events.jsonl")
      events = read_recent_events(events_path, STATUS_TAIL_LINES)
      walk_events = read_recent_events(events_path, CURRENT_AGENT_WALK_LINES)
      body = render_status_body(last_record, events, walk_events)
      write_atomic(File.join(task_folder, "status.md"), body)
    end

    def render_status_body(last_record, events, walk_events = events)
      current_agent = current_agent(walk_events)
      last_message = last_record["message"].to_s.empty? ? EM_DASH : last_record["message"].to_s
      lines = [
        "# Status: #{last_record.fetch('slug')}",
        "Stage:         #{last_record.fetch('stage')}",
        "Updated:       #{last_record.fetch('ts')}",
        "Last event:    #{last_record.fetch('event_type')} #{EM_DASH} #{last_message}",
        "Current agent: #{current_agent || EM_DASH}",
        "",
        "## Recent events (last #{STATUS_TAIL_LINES})"
      ]
      if events.empty?
        lines << "- (no events yet)"
      else
        events.each do |event|
          agent = event["agent"].to_s.empty? ? EM_DASH : event["agent"].to_s
          message = event["message"].to_s.empty? ? EM_DASH : event["message"].to_s
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

    # Read up to `limit` trailing events without materializing the whole
    # file. Reads the last STATUS_TAIL_BYTES, splits on newlines, and
    # parses each line. Skips unparseable lines (e.g. a torn final write
    # that the reader observes before the writer's append completes —
    # the emit itself is atomic, but the very last record may not yet
    # have its trailing newline visible to other processes on some FS).
    def read_recent_events(path, limit)
      return [] unless File.exist?(path)

      File.open(path, "rb") do |file|
        size = file.size
        offset = [ size - STATUS_TAIL_BYTES, 0 ].max
        file.seek(offset)
        chunk = file.read
        next [] unless chunk

        lines = chunk.split("\n")
        # When we truncated mid-line on the leading edge, drop the
        # partial fragment so we never feed JSON.parse half a record.
        lines.shift if offset.positive? && !lines.empty?
        lines.last(limit).filter_map do |line|
          next nil if line.empty?

          begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end
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
        rescue Errno::EINVAL, Errno::ENOSYS, IOError
          # fsync best-effort: some filesystems / pipes don't support it.
          # Narrow rescue avoids masking genuine bugs (e.g. NoMethodError)
          # that the broader StandardError would have swallowed.
          nil
        end
      end
      File.rename(tmp, path)
    ensure
      # Race-free cleanup: if rename succeeded tmp is gone; if it failed
      # tmp still exists. Swallow ENOENT instead of round-tripping through
      # File.exist?, which races against the rename above.
      begin
        File.delete(tmp) if tmp
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
