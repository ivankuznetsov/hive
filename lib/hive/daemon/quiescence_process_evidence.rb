module Hive
  module Daemon
    module QuiescenceProcessEvidence
      private
      def final_remaining
        unresolved = remaining_without_capability(live_process_evidence)
        final_capability = @capability.call
        capability_entries = if final_capability.eligible?
          []
        else
          final_capability.disqualifying_inventory.map do |entry|
            entry.merge("unknown_reason" => final_capability.reason)
          end
        end
        unresolved + capability_entries
      end

      def remaining_without_capability(live)
        processes = live.map { |entry| remaining_process(entry) }
        attempts = live_attempt_rows.map do |row|
          {
            "attempt_id" => row.fetch(:attempt_id), "task_id" => row[:task_id],
            "role" => "attempt", "last_known_state" => row.fetch(:state),
            "pid" => nil, "unknown_reason" => "attempt_not_reconciled"
          }
        end
        processes + attempts + unresolved_reservations
      end

      def signal_processes(signal, live)
        identities = live.flat_map do |entry|
          row = entry.fetch(:row)
          [ identity_hash(row), *entry.fetch(:descendants, []) ]
        end
        identities.uniq { |identity| [ identity["pid"], identity["start_fingerprint"] ] }
          .each do |identity|
            next if identity.fetch("pid") == Process.pid
            next if identity["unknown_reason"]
            next unless @process_identity.status(identity) == :matching
          @signaler.call(signal, identity.fetch("pid"))
          rescue Errno::ESRCH
            next
          rescue Errno::EPERM
            signal_failures[[ identity["pid"], identity["start_fingerprint"] ]] =
              "signal_permission_denied"
            next
          end
      end

      def custody_member_evidence(row)
        return [ [], nil ] unless
          row[:custody_mode] == "delegated_cgroup_v2" && row[:custody_path]
        custody_timeout = @budget ? remaining(@budget.escalation_cutoff) : 0.0
        identities = @custody.members(
          row.fetch(:custody_path), timeout_sec: custody_timeout
        ).filter_map do |pid|
          next if pid == Process.pid || pid == row[:pid]
          captured = @process_identity.capture(pid)
          captured ? captured.to_h : {
            "pid" => pid, "start_fingerprint" => nil,
            "session_id" => nil, "process_group_id" => nil,
            "unknown_reason" => "process_identity_unavailable"
          }
        end
        cache = descendant_cache(row)
        observed_pids = identities.map { |identity| identity.fetch("pid") }
        cache.delete_if { |_key, identity| !observed_pids.include?(identity.fetch("pid")) }
        identities.each do |identity|
          cache.delete([ identity.fetch("pid"), nil ]) if identity["start_fingerprint"]
          cache[[ identity.fetch("pid"), identity.fetch("start_fingerprint") ]] = identity
        end
        live = cache.values.reject do |identity|
          next false if identity["unknown_reason"]
          %i[missing mismatched].include?(@process_identity.status(identity))
        end
        [ live, nil ]
      rescue Hive::Error, SystemCallError, IOError, ArgumentError, TypeError => error
        cached = descendant_cache(row).values.reject do |identity|
          next false if identity["unknown_reason"]
          %i[missing mismatched].include?(@process_identity.status(identity))
        end
        [ cached, "custody_inventory_unavailable:#{error.class}" ]
      end

      def live_process_evidence
        inventory_rows.filter_map do |row|
          status = @process_identity.status(identity_hash(row))
          descendants, custody_error = custody_member_evidence(row)
          root_absent = %i[missing mismatched].include?(status)
          next if root_absent && descendants.empty? && custody_error.nil?
          status = :unverifiable if custody_error
          { row: row, status: status, descendants: descendants,
            custody_error: custody_error }
        end
      end

      def descendant_cache(row)
        @descendant_identities ||= {}
        @descendant_identities[row.fetch(:process_id)] ||= {}
      end

      def proof_inventory
        descendants = (@descendant_identities || {}).flat_map do |process_id, entries|
          entries.values.map do |identity|
            identity.merge(
              "process_id" => process_id, "role" => "descendant",
              "origin" => "delegated_cgroup_v2"
            )
          end
        end
        Array(@proof_inventory) + descendants
      end

      def inventory_rows = @registry.active_rows

      def live_attempt_rows
        @database.read do |db|
          db[:attempts].where(state: %w[launching running]).order(:attempt_id).all
        end
      end

      def unresolved_reservations
        @database.read do |db|
          db[:launch_reservations].where(state: "reserved").order(:reservation_id).all.map do |row|
            {
              "reservation_id" => row.fetch(:reservation_id),
              "attempt_id" => row[:attempt_id], "task_id" => row[:task_id],
              "origin" => row.fetch(:origin), "role" => row.fetch(:role),
              "pid" => row[:owner_pid], "last_known_state" => row.fetch(:state)
            }
          end
        end
      rescue Hive::RuntimeControlPlane::Error, Sequel::Error
        []
      end

      def attempt_store_if_needed
        return @attempt_store if @attempt_store
        return nil if live_attempt_rows.empty?

        @attempt_store = Hive::Attempts::Repository.new(
          database: @database, root: Hive::Paths.runtime_payload_root(@state_home),
          create_directories: false
        )
      end

      def remaining_process(entry)
        normalize_process(entry.fetch(:row)).merge(
          "last_known_state" => entry.fetch(:status).to_s,
          "unknown_reason" => entry[:custody_error] ||
            signal_failures[[ entry.dig(:row, :pid), entry.dig(:row, :start_fingerprint) ]] ||
            (entry.fetch(:status) == :unverifiable ? "process_identity_unverifiable" : nil),
          "descendants" => entry.fetch(:descendants, [])
        )
      end

      def durable_interrupted_attempts(generation)
        @database.read do |db|
          db[:attempts].where(state: "terminal", outcome: "interrupted").all.filter_map do |row|
            receipt = Hive::RuntimeControlPlane::Codec.load_json(
              row.fetch(:terminal_receipt_json)
            )
            row.fetch(:attempt_id) if receipt["pause_generation"] == Integer(generation)
          rescue Hive::RuntimeControlPlane::CodecError, KeyError, TypeError
            nil
          end
        end
      end

      def signal_failures = @signal_failures ||= {}

      def normalize_process(row)
        {
          "process_id" => row[:process_id], "reservation_id" => row[:reservation_id],
          "task_id" => row[:task_id], "attempt_id" => row[:attempt_id],
          "service_identity" => row[:service_identity], "origin" => row[:origin],
          "role" => row[:role], "pid" => row[:pid],
          "start_fingerprint" => row[:start_fingerprint],
          "session_id" => row[:session_id], "process_group_id" => row[:process_group_id],
          "custody_mode" => row[:custody_mode], "custody_path" => row[:custody_path]
        }
      end

      def identity_hash(row)
        {
          "pid" => row[:pid], "start_fingerprint" => row[:start_fingerprint],
          "session_id" => row[:session_id], "process_group_id" => row[:process_group_id]
        }
      end
    end
  end
end
