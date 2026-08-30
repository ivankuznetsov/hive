require "hive/runtime_control_plane"

module Hive
  module TaskCounter
    module_function

    def next!
      database.transaction do |db|
        counter = dataset(db)
        current = counter.get(:value) || inferred_next(db)
        write(db, current + 1)
        current
      end
    end

    def next_or_nil
      next!
    rescue RuntimeControlPlane::Error, Sequel::DatabaseError
      nil
    end

    def peek
      database.read { |db| dataset(db).get(:value) || inferred_next(db) }
    end

    def seed_at_least!(next_id)
      database.transaction do |db|
        counter = dataset(db)
        value = [ counter.get(:value) || 1, Integer(next_id), 1 ].max
        write(db, value)
        value
      end
    end

    def database = @database || RuntimeControlPlane.database
    def database=(value)
      @database = value
    end

    def dataset(db)
      db[:task_counters].where(
        installation_id: db[:installations].get(:installation_id), namespace: "tasks"
      )
    end

    def write(db, value)
      timestamp = RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      db[:task_counters].insert_conflict(
        target: %i[installation_id namespace], update: { value: value, updated_at: timestamp }
      ).insert(
        installation_id: db[:installations].get(:installation_id),
        namespace: "tasks", value: value, updated_at: timestamp
      )
    end

    def inferred_next(db)
      db[:task_subjects].select_map(:task_id).filter_map do |value|
        Integer(value, exception: false)
      end.max.to_i + 1
    end
  end
end
