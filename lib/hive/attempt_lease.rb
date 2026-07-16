require "time"

module Hive
  AttemptLease = Data.define(
    :id,
    :namespace,
    :key,
    :group,
    :owner_pid,
    :owner_start_time,
    :provenance,
    :acquired_at,
    :heartbeat_at,
    :expires_at,
    :state
  ) do
    def active?
      state == "active"
    end

    def terminal?
      state == "completed"
    end

    def to_h
      {
        "id" => id,
        "namespace" => namespace,
        "key" => key,
        "group" => group,
        "owner_pid" => owner_pid,
        "owner_start_time" => owner_start_time,
        "provenance" => provenance,
        "acquired_at" => acquired_at.utc.iso8601(6),
        "heartbeat_at" => heartbeat_at.utc.iso8601(6),
        "expires_at" => expires_at.utc.iso8601(6),
        "state" => state
      }
    end

    def self.from_h(value)
      new(
        id: value.fetch("id"),
        namespace: value.fetch("namespace"),
        key: value.fetch("key"),
        group: value.fetch("group"),
        owner_pid: value.fetch("owner_pid"),
        owner_start_time: value["owner_start_time"],
        provenance: value.fetch("provenance", {}),
        acquired_at: Time.iso8601(value.fetch("acquired_at")),
        heartbeat_at: Time.iso8601(value.fetch("heartbeat_at")),
        expires_at: Time.iso8601(value.fetch("expires_at")),
        state: value.fetch("state")
      )
    end
  end
end
