# frozen_string_literal: true

require "socket"
require "hive/errors"
require "hive/pid_file"
require "hive/runtime_control_plane/codec"

module Hive
  # One proof contract for automatic and operator-confirmed owner recovery.
  module CommandOwnerProof
    module_function

    def dead(row, host: Socket.gethostname, alive: Hive::PidFile.method(:alive?),
             ownership: Hive::PidFile.method(:ownership), clock: -> { Time.now.utc })
      pid = row[:owner_pid]
      recorded = row[:owner_process_start]
      return unless row[:owner_host] == host && pid.is_a?(Integer) && pid.positive? && recorded

      classification = Hive::PidFile.death_classification(
        pid: pid, recorded_start_time: recorded, alive: alive, ownership: ownership
      )
      return unless %i[dead reused].include?(classification)

      [ row, {
        "host" => host, "pid" => pid, "recorded_start_time" => recorded,
        "alive" => classification != :dead, "ownership" => classification.to_s,
        "observed_at" => Hive::RuntimeControlPlane::Codec.dump_time(clock.call.utc)
      } ]
    end

    def dead!(row, **options)
      pair = dead(row, **options)
      return pair.last if pair

      raise Hive::CommandUnresolved.new(
        reason: "command_orphaned_pin",
        message: "owner identity is remote, incomplete, live, or unverifiable"
      )
    end
  end
end
