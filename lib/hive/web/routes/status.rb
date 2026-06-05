require "json"
require "open3"
require "hive/task"
require "hive/stages"

module Hive
  module Web
    class App < Sinatra::Base
      get "/" do
        @snapshot = settings.status_feed.snapshot
        erb :grid
      end

      get "/events" do
        # Reject (and emit the 503 body) BEFORE switching the response to
        # text/event-stream, so the error reads as plain text rather than a
        # malformed SSE frame.
        halt 503, "too many live connections" unless settings.sse_limiter.acquire
        content_type "text/event-stream"
        # `stream` itself can raise before the block runs; an ensure at the
        # route level guarantees the acquired slot is released even then, so a
        # slot can never leak permanently.
        begin
          stream(:keep_open) do |out|
            out << ": connected\n\n"
            settings.status_feed.each_snapshot(on_idle: -> { out << ": keep-alive\n\n" }) do |payload|
              out << "event: status\n"
              out << "data: #{JSON.generate(payload)}\n\n"
            end
          rescue IOError
            nil
          ensure
            settings.sse_limiter.release
            # Close on the terminal path so `:keep_open` doesn't park the
            # thread waiting for writes after the subscriber loop ends (e.g.
            # the client disconnected and a write raised IOError).
            out.close unless out.closed?
          end
        rescue StandardError
          settings.sse_limiter.release
          raise
        end
      end

      get "/tasks/:project/:slug" do
        project = find_project!(params["project"])
        row = task_row(project, params["slug"])
        halt 404, "unknown task" unless row
        @project = project
        @row = row
        @files = artifact_files(row)
        erb :task
      end

      get "/tasks/:project/:slug/diff" do
        project = find_project!(params["project"])
        slug = safe_slug!(params["slug"])
        cfg = Hive::Config.load(project["path"])
        worktree_root = cfg["worktree_root"] || File.expand_path("~/Dev/#{project["name"]}.worktrees")
        worktree = File.join(worktree_root, slug)
        halt 404, "worktree not found" unless File.directory?(worktree)
        out, err, status = Open3.capture3("git", "-C", worktree, "diff", "--")
        # On a git failure (e.g. a corrupt worktree) `out` is empty and `err`
        # carries the reason; returning that as a 200 "diff" misleads the
        # operator. Surface the failure as a 422 instead of rendering stderr
        # as if it were a real diff.
        halt 422, "git diff failed: #{err.strip}" unless status.success?
        @diff = out
        erb :diff
      end

      # Frame a log chunk as a single named SSE `log` event with proper
      # multi-line `data:` framing (one `data:` line per source line) rather
      # than the old literal `\n`-escape, which mangled multi-line output. A
      # class method so it can be unit-tested without booting a stream.
      def self.encode_log_event(chunk)
        data = chunk.split("\n").map { |line| "data: #{line}" }.join("\n")
        "event: log\n#{data}\n\n"
      end

      get "/tasks/:project/:slug/logs" do
        project = find_project!(params["project"])
        slug = safe_slug!(params["slug"])
        log = latest_log(project, slug)
        halt 404, "log not found" unless log
        # Reject (and emit the 503 body) BEFORE switching to text/event-stream
        # so the error isn't framed as a malformed SSE event.
        halt 503, "too many live connections" unless settings.sse_limiter.acquire
        content_type "text/event-stream"
        begin
          stream(:keep_open) { |out| tail_log_stream(out, log) }
        rescue StandardError
          settings.sse_limiter.release
          raise
        end
      end

      helpers do
        # Tail `log` to the SSE `out`, emitting named `log` events the
        # frontend can subscribe to. Breaks (releasing the slot) when the
        # client disconnects (`out.closed?` / a write IOError) or after a
        # bounded idle period, so a parked stream never pins a thread.
        def tail_log_stream(out, log)
          tick = settings.log_stream_tick
          idle_limit = settings.log_stream_idle_timeout
          idle = 0.0
          File.open(log, "r") do |f|
            f.seek(0, IO::SEEK_END)
            loop do
              # Cheap disconnect probe: a closed client socket lets us bail
              # before the next blocking write would (a regular file is always
              # `select`-readable, so we can't wait on the log itself).
              break if out.closed?

              chunk = f.read
              if chunk.to_s.empty?
                # No new log bytes. Sleep one tick, then emit a keep-alive
                # comment — a dead socket raises IOError on this write, and a
                # bounded idle budget guarantees we stop tailing a quiet log
                # whose client has gone instead of parking the thread forever.
                sleep tick
                out << ": keep-alive\n\n"
                idle += tick
                break if idle >= idle_limit
              else
                idle = 0.0
                out << self.class.encode_log_event(chunk)
              end
            end
          end
        rescue IOError
          # The client went away mid-write; stop tailing and release below.
          nil
        ensure
          settings.sse_limiter.release
          # `stream(:keep_open)` will not finish on its own when the block
          # returns, so explicitly close the connection on every terminal
          # path (idle timeout, client gone) — otherwise the stream parks
          # waiting for more writes and the thread/slot never frees.
          out.close unless out.closed?
        end
      end

      helpers do
        # Reject a `slug` that isn't a real task-folder name before it reaches
        # File.join / git / a log glob. Without this, a `../`-style slug would
        # let the diff route read any reachable git repo's working diff and the
        # logs route stream any *.log under a traversable dir.
        def safe_slug!(slug)
          halt 404, "unknown task" unless Hive::Stages.task_slug?(slug.to_s)

          slug
        end

        def task_row(project, slug)
          snapshot = settings.status_feed.snapshot
          payload = snapshot["projects"].find { |p| p["name"] == project["name"] }
          payload && payload.fetch("tasks", []).find { |task| task["slug"] == slug }
        end

        def artifact_files(row)
          folder = row["folder"]
          return [] unless folder && File.directory?(folder)

          %w[idea.md brainstorm.md plan.md task.md pr.md summary.md artifact.md].filter_map do |name|
            path = File.join(folder, name)
            [ name, File.read(path) ] if File.file?(path)
          end
        end

        def latest_log(project, slug)
          dir = File.join(project["hive_state_path"], "logs", slug)
          Dir.glob(File.join(dir, "*.log")).max_by { |path| File.mtime(path) }
        end
      end
    end
  end
end
