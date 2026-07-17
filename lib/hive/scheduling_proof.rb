require "hive/scheduling_proof/action_projector"
require "hive/scheduling_proof/freshness"
require "hive/scheduling_proof/projector"
require "hive/scheduling_proof/reason"

module Hive
  # Read-only explanations derived from the same durable identities and
  # scheduler decisions that authorize work. Nothing in this namespace is an
  # admission, retry, recovery, merge, or archive authority.
  module SchedulingProof
    SNAPSHOT_SCHEMA = "hive-scheduler-snapshot".freeze
    SNAPSHOT_SCHEMA_VERSION = 1
  end
end
