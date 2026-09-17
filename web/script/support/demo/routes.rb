require "json"

module HiveDemo
  # Canonical path-based route graph for the exported snapshot. Every internal
  # link is resolved through this map; unknown routes are not exported.
  class Routes
    Route = Data.define(:path, :page, :title, :kind, :group, :project, :task, :state, :view)

    attr_reader :snapshot

    def initialize(snapshot)
      @snapshot = snapshot
      @by_path = {}
      @task_routes = {}
      build
    end

    def manifest
      @by_path.values.sort_by(&:path).map do |route|
        {
          "path" => route.path,
          "page" => route.page,
          "title" => route.title,
          "kind" => route.kind.to_s,
          "group" => route.group,
          "project" => route.project,
          "task" => route.task,
          "state" => route.state,
          "view" => route.view
        }.compact
      end
    end

    def include?(path)
      stripped = path.to_s.split("#", 2).first
      @by_path.key?(stripped)
    end

    def fetch(path)
      @by_path.fetch(path.to_s.split("#", 2).first)
    end

    def task_path(project, slug)
      @task_routes.fetch([ project.to_s, slug.to_s ])
    rescue KeyError
      raise KeyError, "no exported route for task #{project}/#{slug}"
    end

    def document_path(project, slug, document_path)
      "#{task_path(project, slug)}/documents/#{document_path}"
    end

    def change_path(project, slug)
      "#{task_path(project, slug)}/change"
    end

    def board_path(project = nil, state = nil)
      path_for_status(view: "board", project: project, state: state)
    end

    def grid_path(project = nil, state = nil)
      path_for_status(view: "grid", project: project, state: state)
    end

    def archive_path(project = nil, view: nil)
      return done_path(project) if view.to_s == "board"

      project ? "/archive/#{project}" : "/archive"
    end

    def done_path(project = nil)
      project ? "/done/#{project}" : "/done"
    end

    def status_states
      @status_states ||= begin
        all = Hash.new(0)
        snapshot.projects.each do |project|
          project.active_tasks.each do |task|
            all[TaskDisplay.new(task, fresh: true).state] += 1
          end
        end
        all
      end
    end

    def project_states(project)
      counts = Hash.new(0)
      project.active_tasks.each do |task|
        counts[TaskDisplay.new(task, fresh: true).state] += 1
      end
      counts
    end

    private

    def path_for_status(view:, project:, state:)
      if project.nil? || project.to_s.empty?
        return state ? "/#{view}/all/#{state}" : (view == "board" ? "/" : "/grid")
      end

      base = "/#{view}/#{project}"
      state ? "#{base}/#{state}" : base
    end

    def build
      add("/", "Status", :status, "status", view: "board")
      add("/grid", "Status grid", :status, "status", view: "grid")
      add("/archive", "Archive", :archive, "archive")
      add("/done", "Done", :archive, "archive", view: "board")
      add("/repos", "Repositories", :repos, "repos")
      add("/honeycombs/workflows", "Workflows", :workflows, "honeycombs", project: "hive")
      add("/honeycombs/modules", "Modules", :modules, "honeycombs", project: "hive")
      add("/patrol", "Patrol", :patrol, "patrol", project: "hive")
      add("/unavailable/agents", "Agents unavailable", :unavailable, "agents")
      add("/unavailable/telegram", "Telegram unavailable", :unavailable, "telegram")

      digest_date = snapshot.digest.fetch("local_date")
      add("/digest/#{digest_date}", "Digest #{digest_date}", :digest, "digest", project: "hive")

      snapshot.projects.each do |project|
        name = project.name
        add("/board/#{name}", "#{name} board", :status, "status", project: name, view: "board")
        add("/grid/#{name}", "#{name} grid", :status, "status", project: name, view: "grid")
        add("/archive/#{name}", "#{name} archive", :archive, "archive", project: name)
        add("/done/#{name}", "#{name} done", :archive, "archive", project: name, view: "board")
        project_states(project).keys.concat(TaskDisplay::STATES.keys).uniq.each do |state|
          add("/board/#{name}/#{state}", "#{name} board · #{state}", :status, "status", project: name, view: "board", state: state)
          add("/grid/#{name}/#{state}", "#{name} grid · #{state}", :status, "status", project: name, view: "grid", state: state)
        end
      end

      TaskDisplay::STATES.each_key do |state|
        add("/board/all/#{state}", "All projects board · #{state}", :status, "status", view: "board", state: state)
        add("/grid/all/#{state}", "All projects grid · #{state}", :status, "status", view: "grid", state: state)
      end

      snapshot.task_rows.each do |row|
        task = snapshot.task(row.fetch("project"), row.fetch("id"))
        base = "/tasks/#{row.fetch('project')}/#{row.fetch('slug')}"
        add(base, row.fetch("title"), :task, "task", project: row.fetch("project"), task: base)
        @task_routes[[ row.fetch("project"), row.fetch("slug") ]] = base
        task.fetch("documents").each do |document|
          add("#{base}/documents/#{document.fetch('name')}", "#{document.fetch('name')} · #{row.fetch('title')}",
              :document, "task", project: row.fetch("project"), task: base)
        end
        add("#{base}/change", "Change evidence · #{row.fetch('title')}", :change, "task",
            project: row.fetch("project"), task: base) if task["change"]
      end
    end

    def add(path, title, kind, group, project: nil, task: nil, state: nil, view: nil)
      raise "duplicate exported route #{path}" if @by_path.key?(path)

      page = path == "/" ? "index.html" : "#{path.delete_prefix('/')}/index.html"
      @by_path[path] = Route.new(path: path, page: page, title: title, kind: kind, group: group,
                                 project: project, task: task, state: state, view: view)
    end
  end
end
