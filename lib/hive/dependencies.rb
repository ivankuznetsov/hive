require "hive/stages"

module Hive
  module Dependencies
    Result = Data.define(:blocked_by, :dependency_stage, :blocked, :unresolved)

    module_function

    def resolve(depends_on:, tasks:, threshold_stage:, task: nil)
      dependency = normalize_depends_on(depends_on)
      return Result.new(blocked_by: nil, dependency_stage: nil, blocked: false, unresolved: false) unless dependency

      prerequisite = find_task(dependency, tasks)
      if prerequisite.nil? || same_task?(prerequisite, task)
        return Result.new(blocked_by: nil, dependency_stage: nil, blocked: true, unresolved: true)
      end

      stage = stage_name_for(prerequisite)
      blocked = stage_index_for(prerequisite) < threshold_index(threshold_stage)
      Result.new(blocked_by: task_slug(prerequisite), dependency_stage: stage, blocked: blocked, unresolved: false)
    end

    def base_branch_for(depends_on:, tasks:, default_branch:, task: nil)
      dependency = normalize_depends_on(depends_on)
      return default_branch unless dependency

      prerequisite = find_task(dependency, tasks)
      return default_branch if prerequisite.nil? || same_task?(prerequisite, task)

      task_slug(prerequisite) || default_branch
    end

    def find_task(depends_on, tasks)
      tasks.find { |candidate| task_slug(candidate) == depends_on } ||
        (numeric?(depends_on) ? tasks.find { |candidate| task_id(candidate) == Integer(depends_on) } : nil)
    end

    def normalize_depends_on(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def numeric?(value)
      value.to_s.match?(/\A\d+\z/)
    end

    def same_task?(left, right)
      return false unless right

      left_slug = task_slug(left)
      right_slug = task_slug(right)
      return true if left_slug && right_slug && left_slug == right_slug

      left_id = task_id(left)
      right_id = task_id(right)
      left_id && right_id && left_id == right_id
    end

    def task_slug(task)
      field(task, :slug) || field(task, "slug")
    end

    def task_id(task)
      raw = field(task, :id) || field(task, "id")
      return raw if raw.is_a?(Integer)
      return nil if raw.nil? || raw.to_s.strip.empty?

      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end

    def stage_index_for(task)
      raw = field(task, :stage_index) || field(task, "stage_index")
      return raw if raw.is_a?(Integer)
      return Integer(raw) if raw

      stage = field(task, :stage) || field(task, "stage") ||
              field(task, :dependency_stage) || field(task, "dependency_stage")
      resolved = Hive::Stages.resolve(stage.to_s)
      return Hive::Stages::DIRS.index(resolved) + 1 if resolved

      raise ArgumentError, "dependency task #{task_slug(task).inspect} has no valid stage"
    end

    def stage_name_for(task)
      stage = field(task, :stage) || field(task, "stage")
      resolved = Hive::Stages.resolve(stage.to_s)
      return resolved if resolved

      Hive::Stages::DIRS.fetch(stage_index_for(task) - 1)
    end

    def threshold_index(threshold_stage)
      resolved = Hive::Stages.resolve(threshold_stage.to_s)
      raise ArgumentError, "unknown dependency gate stage #{threshold_stage.inspect}" unless resolved

      Hive::Stages::DIRS.index(resolved) + 1
    end

    def field(task, key)
      if task.respond_to?(:key?) && task.key?(key)
        task[key]
      elsif task.respond_to?(key)
        task.public_send(key)
      end
    end
  end
end
