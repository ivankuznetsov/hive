require "json"
require "pathname"

module HiveDemo
  # The real Hive web view object plus read access to captured package fields.
  class Workflow < ::Workflow
    delegate :[], :dig, :fetch, to: :attributes
  end

  # Read-only presentation layer over the reviewed public snapshot. It never
  # reads the operator installation, the network, or live Hive registries.
  class Snapshot
    ROOT = File.expand_path("../../../../demo/snapshot", __dir__)

    attr_reader :root, :dataset, :status, :workflows, :modules, :patrol, :digest, :repos

    def self.load(root = ROOT)
      new(root)
    end

    def self.resolve(root, path)
      raise KeyError, "snapshot path must be relative: #{path}" if Pathname.new(path.to_s).absolute?

      root_path = Pathname.new(root).expand_path
      absolute = (root_path + path.to_s).expand_path
      unless absolute.to_s.start_with?("#{root_path}#{File::SEPARATOR}")
        raise KeyError, "snapshot path escapes the snapshot root: #{path}"
      end

      absolute
    end

    def initialize(root)
      @root = Pathname.new(root)
      @dataset = read("data/snapshot.json")
      @status = read("data/status.json")
      @workflows = read("data/workflows.json")
      @modules = read("data/modules.json")
      @patrol = read("data/patrol.json")
      @digest = read("data/digest.json")
      @repos = read("data/repos.json")
      @tasks = @dataset.fetch("tasks").to_h do |row|
        [ [ row.fetch("project"), row.fetch("id") ], read(row.fetch("path")) ]
      end
      @documents = {}
    end

    def projects
      @projects ||= @status.fetch("projects").map do |attributes|
        Project.new(name: attributes.fetch("name"), repository: attributes.fetch("repository"),
                    url: attributes.fetch("url"), visibility: attributes["visibility"], tasks: tasks_for(attributes.fetch("name")))
      end
    end

    def project(name) = projects.find { |candidate| candidate.name == name }

    def scope = @dataset.fetch("scope")

    def task_rows
      @dataset.fetch("tasks")
    end

    def task(project, id)
      row = @tasks.fetch([ project, id ])
      Task.new(project: self.project(project), attributes: row)
    rescue KeyError
      raise KeyError, "unknown snapshot task #{project}:#{id}"
    end

    def task_for_slug(project, slug)
      row = @dataset.fetch("tasks").find { |candidate| candidate.fetch("project") == project && candidate.fetch("slug") == slug }
      raise KeyError, "unknown snapshot task #{project}/#{slug}" unless row

      task(row.fetch("project"), row.fetch("id"))
    end

    def document(task, name)
      @documents[[ task.fetch("project"), task.fetch("id"), name ]] ||= begin
        record = task.fetch("documents").find { |candidate| candidate.fetch("name") == name }
        raise KeyError, "unknown document #{name}" unless record

        Document.new(record: record, root: @root)
      end
    end

    def change_content(task)
      change = task.change
      raise KeyError, "#{task['project']}:#{task['id']} has no change evidence" unless change&.fetch("path")

      Snapshot.resolve(@root, change.fetch("path")).read
    end

    def documents(task, role: nil)
      records = task.fetch("documents")
      records = records.select { |record| record["role"] == role } if role
      records.map { |record| document(task, record.fetch("name")) }
    end

    def digest_view(requested_date:)
      DailyDigest.new(@digest, requested_date: requested_date,
                      current_projects: @digest.fetch("projects"),
                      link_resolver: method(:destination))
    end

    # A digest task link resolves only when that exact task was exported.
    def destination(project, row)
      return nil unless row.is_a?(Hash)

      slug = row["task_slug"]
      return nil if slug.to_s.empty?

      candidate = @tasks.values.find do |task|
        task["project"] == project["name"] && task["slug"] == slug && task["archived"] != true
      end
      return nil unless candidate

      { project: candidate.fetch("project"), slug: candidate.fetch("slug") }
    end

    def captured_at = @dataset.fetch("captured_at")

    def ui_sha = @dataset.fetch("ui_sha")

    def source_note = @status.fetch("source")

    private

    def tasks_for(project_name)
      @dataset.fetch("tasks").select { |row| row["project"] == project_name }
    end

    def read(path)
      JSON.parse(Snapshot.resolve(@root, path).read)
    end
  end

  class Project
    attr_reader :name, :repository, :url, :visibility, :attributes, :rows

    def initialize(name:, repository:, url:, visibility:, tasks:)
      @name = name
      @repository = repository
      @url = url
      @visibility = visibility
      @attributes = { "name" => name, "repository" => repository, "url" => url }
      @rows = tasks
    end

    def active_tasks = task_rows("active")

    def archived_tasks = task_rows(nil).reject { |row| row["role"] == "active" }

    def with_rows(rows)
      Project.new(name: name, repository: repository, url: url, visibility: visibility, tasks: rows)
    end

    def [](key) = attributes[key]

    private

    def task_rows(role)
      rows = role ? @rows.select { |row| row["role"] == role } : @rows
      rows.map { |row| Task.new(project: self, attributes: row) }
    end
  end

  class Task
    attr_reader :project, :attributes

    def initialize(project:, attributes:)
      @project = project
      @attributes = attributes
    end

    def slug = attributes.fetch("slug")
    def title = attributes.fetch("title")
    def id = attributes.fetch("id")
    def archived? = attributes["archived"] == true

    def [](key) = key == "project" ? project.name : attributes[key]
    def dig(*keys) = attributes.dig(*keys)
    def fetch(...) = attributes.fetch(...)

    def recovery = nil
    def recovery_action_visible? = false
    def recovery_action_enabled? = false
    def passable? = false
    def worktree? = false
    def dispatch_action = nil
    def run_verb = nil

    def publication = attributes["publication"]
    def change = attributes["change"]
    def questions = attributes.fetch("questions", [])
  end

  class Document
    attr_reader :record

    def initialize(record:, root:)
      @record = record
      @root = root
    end

    def name = record.fetch("name")
    def role = record.fetch("role")
    def path = record.fetch("path")
    def bytes = record.fetch("bytes")
    def content = (@content ||= Snapshot.resolve(@root, path).read)
  end
end
