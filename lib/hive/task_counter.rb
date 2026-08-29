require "hive/runtime_control_plane"

module Hive
  module TaskCounter
    module_function

    DEFAULT_NEXT_ID = 1
    NAMESPACE = "tasks".freeze

    def next!(**)
      timestamp = RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |db|
        installation_id = db[:installations].get(:installation_id)
        row = db[:task_counters].where(
          installation_id: installation_id, namespace: NAMESPACE
        ).first
        value = row ? row.fetch(:value) : DEFAULT_NEXT_ID
        if row
          db[:task_counters].where(
            installation_id: installation_id, namespace: NAMESPACE,
            value: value
          ).update(value: value + 1, updated_at: timestamp)
        else
          db[:task_counters].insert(
            installation_id: installation_id, namespace: NAMESPACE,
            value: value + 1, updated_at: timestamp
          )
        end
        value
      end
    end

    def next_or_nil(**options)
      next!(**options)
    rescue RuntimeControlPlane::Error, Sequel::DatabaseError
      nil
    end

    def peek
      database.read do |db|
        installation_id = db[:installations].get(:installation_id)
        db[:task_counters].where(
          installation_id: installation_id, namespace: NAMESPACE
        ).get(:value) || DEFAULT_NEXT_ID
      end
    end

    def seed_at_least!(next_id)
      floor = [ Integer(next_id), DEFAULT_NEXT_ID ].max
      timestamp = RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |db|
        installation_id = db[:installations].get(:installation_id)
        dataset = db[:task_counters].where(
          installation_id: installation_id, namespace: NAMESPACE
        )
        current = dataset.get(:value) || DEFAULT_NEXT_ID
        value = [ current, floor ].max
        dataset.insert_conflict(
          target: %i[installation_id namespace],
          update: { value: value, updated_at: timestamp }
        ).insert(
          installation_id: installation_id, namespace: NAMESPACE,
          value: value, updated_at: timestamp
        )
        value
      end
    end

    def database
      @database || RuntimeControlPlane.database
    end

    def database=(value)
      @database = value
    end
  end
end
