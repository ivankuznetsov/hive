class StatusVisibility
  class << self
    def projects(payload)
      payload.fetch("projects", []).map { |project| visible_project(project) }
    end

    private

    def visible_project(project)
      workflows = project.fetch("workflows", []).index_by { |workflow| workflow["id"].to_s }
      visible_tasks = project.fetch("tasks", []).reject do |task|
        workflow = workflows[task["workflow"].to_s]
        terminal = workflow&.fetch("stages", [])&.last&.dig("dir") == task["stage"]
        Hive::ArchiveFilter.hide?(
          stage: task["stage"], terminal: terminal,
          mtime: parse_time(task["mtime"]), folder_mtime: parse_time(task["folder_mtime"])
        )
      end
      project.merge("tasks" => visible_tasks)
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
