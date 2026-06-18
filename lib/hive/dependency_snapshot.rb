require "hive/stages"
require "hive/task_meta"

module Hive
  module DependencySnapshot
    module_function

    def tasks(project_root)
      Hive::Stages::DIRS.each_with_index.flat_map do |stage, index|
        stage_dir = File.join(project_root, ".hive-state", "stages", stage)
        next [] unless File.directory?(stage_dir)

        Dir.children(stage_dir).sort.filter_map do |entry|
          folder = File.join(stage_dir, entry)
          next unless File.directory?(folder)

          meta = Hive::TaskMeta.read(folder)
          {
            slug: meta[:slug] || entry,
            id: meta[:id],
            stage: stage,
            stage_index: index + 1
          }
        end
      end
    end

    def current_task(task)
      {
        slug: task.slug,
        id: task.respond_to?(:id) ? task.id : nil
      }
    end

    def depends_on(task)
      return task.depends_on if task.respond_to?(:depends_on)

      Hive::TaskMeta.read(task.folder)[:depends_on] if task.respond_to?(:folder)
    end
  end
end
