require "fileutils"
require "json"
require "securerandom"
require "time"
require "hive/task_journal/envelope"

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
      clean_exit_auto_committed
      claude_completion_fallback
    ].freeze

    STATUS_TAIL_LINES = 20
    # Width of the trailing window scanned to recover the "current agent"
    # line in status.md. Must comfortably exceed STATUS_TAIL_LINES so a
    # long-running agent whose agent_start scrolled past the recent-events
    # tail still renders honestly.
    CURRENT_AGENT_WALK_LINES = 200
    # Baseline trailing-byte read window. We scale this up when the caller
    # asks for more lines than STATUS_TAIL_LINES so the walk honors
    # CURRENT_AGENT_WALK_LINES even when records grow past the assumed
    # average (~140 chars → 100 records per 16 KiB).
    STATUS_TAIL_BYTES = 16 * 1024
    # Upper bound on per-emit message size before the record is encoded.
    # Keeps the full JSON line well below the single-write append budget
    # so concurrent emitters cannot interleave bytes within a record.
    MAX_MESSAGE_BYTES = 1024
    MESSAGE_TRUNCATION_SUFFIX = "…[truncated]".freeze

    EM_DASH = "—".freeze

    module_function

    # Append-only event log for task-local lifecycle observability.
    #
    # Each emit issues one O_APPEND syswrite of a short JSON line so the
    # write reaches the kernel as a single write(2) call. On Linux ext4/xfs
    # an O_APPEND single-syscall append is atomic against concurrent
    # appenders via the inode lock; we cap message size (see
    # MAX_MESSAGE_BYTES) so the full line stays small and well-defined.
    # Authoritative condition records use task-journal.jsonl instead, keeping
    # this legacy telemetry contract homogeneous. status.md is derived state
    # and is rewritten with atomic rename.
    def emit(task_folder:, slug:, stage:, event_type:, agent: nil, message: nil)
      event_type = event_type.to_sym
      unless EVENT_TYPES.include?(event_type)
        raise ArgumentError, "unknown event_type #{event_type.inspect}; valid: #{EVENT_TYPES.inspect}"
      end

      record = Hive::TaskJournal::Envelope.observational(
        slug: slug,
        stage: stage,
        agent: agent,
        event_type: event_type,
        message: message.nil? ? nil : truncate_message(message.to_s)
      )

      FileUtils.mkdir_p(task_folder)
      events_path = File.join(task_folder, "events.jsonl")
      # syswrite issues a single write(2) so the JSON payload + trailing
      # newline arrive at the kernel in one call; splitting that into two
      # writes would void the single-syscall atomicity assumption above.
      line = "#{JSON.generate(record)}\n"
      File.open(events_path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") do |file|
        file.syswrite(line)
      end
      render_status!(task_folder, record)
      record
    rescue SystemCallError => e
      warn "[hive.events] failed to emit #{event_type} for #{task_folder}: #{e.class}: #{e.message}"
      nil
    end

    def truncate_message(message)
      return message if message.bytesize <= MAX_MESSAGE_BYTES

      # Trim by byte budget while staying on a valid UTF-8 boundary so the
      # JSON generator never sees malformed UTF-8 mid-character.
      budget = MAX_MESSAGE_BYTES - MESSAGE_TRUNCATION_SUFFIX.bytesize
      trimmed = message.byteslice(0, budget).to_s
      trimmed.scrub!("")
      "#{trimmed}#{MESSAGE_TRUNCATION_SUFFIX}"
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
    # file. Reads a trailing slice scaled to the requested line count,
    # splits on newlines, and parses each line. Skips unparseable lines
    # (e.g. a torn final write that the reader observes before the
    # writer's append completes — the emit itself is atomic, but the
    # very last record may not yet have its trailing newline visible to
    # other processes on some FS).
    def read_recent_events(path, limit)
      return [] unless File.exist?(path)

      File.open(path, "rb") do |file|
        size = file.size
        offset = [ size - tail_byte_window(limit), 0 ].max
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

    # Scale the read window with the caller's line budget so a
    # CURRENT_AGENT_WALK_LINES=200 walk over heavier records (e.g.
    # 300-byte review-stage messages) still surfaces enough lines.
    # STATUS_TAIL_BYTES is sized for STATUS_TAIL_LINES at the assumed
    # ~140-char average; widen it when the requested limit overshoots.
    def tail_byte_window(limit)
      return STATUS_TAIL_BYTES if limit <= STATUS_TAIL_LINES

      scale_factor = (limit.to_f / STATUS_TAIL_LINES).ceil
      STATUS_TAIL_BYTES * scale_factor
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
