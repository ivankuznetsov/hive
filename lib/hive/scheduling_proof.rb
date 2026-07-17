require "hive/scheduling_proof/action_projector"
require "hive/scheduling_proof/candidate_observation"
require "hive/scheduling_proof/fleet_projector"
require "hive/scheduling_proof/freshness"
require "hive/scheduling_proof/observation_recorder"
require "hive/scheduling_proof/projector"
require "hive/scheduling_proof/reason"
require "hive/scheduling_proof/snapshot_store"
require "hive/scheduling_proof/tick_observation"

module Hive
  # Read-only explanations derived from the same durable identities and
  # scheduler decisions that authorize work. Nothing in this namespace is an
  # admission, retry, recovery, merge, or archive authority.
  module SchedulingProof
    SNAPSHOT_SCHEMA = "hive-scheduler-snapshot".freeze
    SNAPSHOT_SCHEMA_VERSION = 1
  end
end
