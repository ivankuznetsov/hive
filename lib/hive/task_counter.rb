require "hive/runtime_control_plane"

module Hive
  module TaskCounter
    module_function

    def next!
      database.transaction do |db|
        current = db[:installations].get(:next_task_id) || inferred_next(db)
        db[:installations].update(next_task_id: current + 1)
        current
      end
    end

    def next_or_nil
      next!
    rescue RuntimeControlPlane::Error, Sequel::DatabaseError
      nil
    end

    def peek
      database.read { |db| db[:installations].get(:next_task_id) || inferred_next(db) }
    end

    def seed_at_least!(next_id)
      database.transaction do |db|
        value = [ db[:installations].get(:next_task_id) || inferred_next(db), Integer(next_id), 1 ].max
        db[:installations].update(next_task_id: value)
        value
      end
    end

    def database = @database || RuntimeControlPlane.database
    def database=(value)
      @database = value
    end

    def inferred_next(db)
      db[:task_subjects].select_map(:task_id).filter_map do |value|
        Integer(value, exception: false)
      end.max.to_i + 1
    end
  end
end
