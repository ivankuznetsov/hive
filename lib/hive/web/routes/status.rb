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
        content_type "text/event-stream"
        halt 503, "too many live connections" unless settings.sse_limiter.acquire
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
        out, err, = Open3.capture3("git", "-C", worktree, "diff", "--")
        @diff = out.empty? ? err : out
        erb :diff
      end

      get "/tasks/:project/:slug/logs" do
        project = find_project!(params["project"])
        slug = safe_slug!(params["slug"])
        log = latest_log(project, slug)
        halt 404, "log not found" unless log
        content_type "text/event-stream"
        halt 503, "too many live connections" unless settings.sse_limiter.acquire
        stream(:keep_open) do |out|
          File.open(log, "r") do |f|
            f.seek(0, IO::SEEK_END)
            loop do
              chunk = f.read
              if chunk.to_s.empty?
                # No new log data: send a keep-alive comment so a closed tab's
                # socket raises promptly instead of parking this thread.
                out << ": keep-alive\n\n"
              else
                out << "data: #{chunk.gsub("\n", "\\n")}\n\n"
              end
              sleep 1
            end
          end
        rescue IOError
          nil
        ensure
          settings.sse_limiter.release
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
