require "json"
require "securerandom"
require "yaml"
require "hive/attempts/process_custody"
require "hive/attempts/process_identity"
require "hive/paths"
require "hive/runtime_control_plane/codec"
require "hive/runtime_control_plane/launch_fence"
require "hive/runtime_control_plane/launch_coverage"

module Hive
  module RuntimeControlPlane
    ProcessRegistration = Data.define(
      :process_id, :reservation_id, :attempt_id, :task_id, :origin, :role,
      :pid, :start_fingerprint, :session_id, :process_group_id,
      :custody_mode, :custody_path
    )

    class LaunchReservation
      attr_reader :id

      def initialize(id, fence)
        @id = id
        @fence = fence
      end

      def release_fence!
        fence = @fence
        @fence = nil
        fence&.release!
      end
    end

    CapabilityVerdict = Data.define(
      :eligible, :reason, :ownership_mode, :disqualifying_inventory
    ) do
      def eligible? = eligible == true
      def to_h
        {
          "eligible" => eligible?, "reason" => reason, "ownership_mode" => ownership_mode,
          "disqualifying_inventory" => disqualifying_inventory
        }
      end
    end

    class ProcessRegistry
      def initialize(database:, state_home: File.dirname(database.path),
                     process_identity: Hive::Attempts::ProcessIdentity.new,
                     custody: Hive::Attempts::ProcessCustody.detect,
                     id_generator: -> { SecureRandom.uuid }, clock: -> { Time.now.utc })
        @database = database
        @state_home = File.expand_path(state_home)
        @process_identity = process_identity
        @custody = custody
        @id_generator = id_generator
        @clock = clock
      end

      def reserve!(origin:, role:, attempt_id: nil, task_id: nil, owner_pid: Process.pid,
                   timeout_sec: 30)
        fence = LaunchFence.new(state_home: @state_home, timeout_sec: timeout_sec)
        fence.acquire_shared!
        reservation_id = @id_generator.call
        owner = @process_identity.capture(owner_pid)
        @database.transaction do |db|
          lifecycle = db[:runtime_lifecycle].first
          db[:launch_reservations].insert(
            reservation_id: reservation_id,
            installation_id: lifecycle.fetch(:installation_id), attempt_id: attempt_id,
            task_id: task_id, origin: origin.to_s, role: role.to_s, state: "reserved",
            admission_generation: lifecycle.fetch(:generation), owner_pid: owner&.pid,
            owner_start_fingerprint: owner&.start_fingerprint,
            created_at: now, updated_at: now
          )
        end
        LaunchReservation.new(reservation_id, fence)
      rescue StandardError
        fence&.release!
        raise
      end

      def register!(reservation_id, pid:, service_identity: nil, proven_child_safe: false,
                    custody_evidence: nil)
        identity = @process_identity.capture(pid)
        unless identity
          raise Unavailable.new(
            "owned process identity is unavailable", code: :process_identity_unavailable,
            action: "stop the process and retry"
          )
        end
        evidence = custody_evidence || @custody.evidence_for(pid)
        process_id = @id_generator.call
        row = nil
        @database.transaction do |db|
          reservation = db[:launch_reservations].where(
            reservation_id: reservation_id, state: "reserved"
          ).first
          raise StaleLifecycle.new("launch reservation is no longer registerable") unless reservation
          lifecycle = db[:runtime_lifecycle].first
          unless reservation.fetch(:admission_generation) == lifecycle.fetch(:generation)
            raise AdmissionClosed.new(
              "launch reservation belongs to a closed admission generation",
              details: { generation: lifecycle.fetch(:generation), phase: lifecycle.fetch(:phase) }
            )
          end
          row = {
            process_id: process_id, installation_id: lifecycle.fetch(:installation_id),
            reservation_id: reservation_id, attempt_id: reservation[:attempt_id],
            task_id: reservation[:task_id], service_identity: service_identity,
            origin: reservation.fetch(:origin), role: reservation.fetch(:role), pid: identity.pid,
            start_fingerprint: identity.start_fingerprint,
            process_group_id: identity.process_group_id, session_id: identity.session_id,
            state: "running", proven_child_safe: proven_child_safe ? 1 : 0,
            custody_mode: evidence.fetch("mode", "unverified"), custody_path: evidence["path"],
            custody_evidence_json: Codec.dump_json(evidence),
            unknown_reason: evidence["eligible"] ? nil : evidence["reason"],
            created_at: now, updated_at: now
          }
          db[:owned_processes].insert(row)
          db[:launch_reservations].where(reservation_id: reservation_id).update(
            state: "registered", updated_at: now
          )
        end
        build_registration(row)
      end

      def rebind!(reservation_id, pid:)
        identity = @process_identity.capture(pid)
        unless identity
          raise Unavailable.new(
            "owned process identity is unavailable after daemonize",
            code: :process_identity_unavailable,
            action: "stop the process and retry"
          )
        end
        row = nil
        @database.transaction do |db|
          scope = db[:owned_processes].where(reservation_id: reservation_id, state: "running")
          raise StaleLifecycle.new("owned process registration is no longer active") unless scope.first

          scope.update(
            pid: identity.pid, start_fingerprint: identity.start_fingerprint,
            process_group_id: identity.process_group_id, session_id: identity.session_id,
            updated_at: now
          )
          row = scope.first
        end
        build_registration(row)
      end

      def mark_stopped_by_reservation!(reservation_id, authority: nil, reason: nil)
        operation = lambda do |db|
          process = db[:owned_processes].where(reservation_id: reservation_id).first
          timestamp = now
          db[:owned_processes].where(reservation_id: reservation_id).update(
            state: "stopped", unknown_reason: reason, stopped_at: timestamp, updated_at: timestamp
          )
          db[:launch_reservations].where(reservation_id: reservation_id).update(
            state: "released", reason: reason, updated_at: timestamp
          )
          process
        end
        if authority
          @database.transaction(authority: authority, &operation)
        else
          process = @database.read { |db| db[:owned_processes].where(reservation_id: reservation_id).first }
          cleanup_owner = process&.fetch(:attempt_id, nil) || "reservation:#{reservation_id}"
          @database.transaction(cleanup_attempt_id: cleanup_owner, &operation)
        end
      end

      def settle_preclose_reservations!(generation:, authority:)
        cancelled = []
        generation = Integer(generation)
        @database.transaction(authority: authority) do |db|
          scope = db[:launch_reservations].where(state: "reserved")
            .where { admission_generation < generation }
          cancelled = scope.select_map(:reservation_id)
          scope.update(state: "cancelled_by_quiesce", reason: "quiescing", updated_at: now)
        end
        cancelled
      end

      def active_rows
        @database.read do |db|
          db[:owned_processes].exclude(state: "stopped").all
        end
      end

      private

      def now = Codec.dump_time(@clock.call)

      def build_registration(row)
        ProcessRegistration.new(
          process_id: row.fetch(:process_id), reservation_id: row.fetch(:reservation_id),
          attempt_id: row[:attempt_id], task_id: row[:task_id], origin: row.fetch(:origin),
          role: row.fetch(:role), pid: row.fetch(:pid),
          start_fingerprint: row.fetch(:start_fingerprint), session_id: row.fetch(:session_id),
          process_group_id: row.fetch(:process_group_id), custody_mode: row.fetch(:custody_mode),
          custody_path: row[:custody_path]
        )
      end
    end

    class QuiescenceCapability
      def initialize(database:, state_home: File.dirname(database.path),
                     process_identity: Hive::Attempts::ProcessIdentity.new,
                     custody: Hive::Attempts::ProcessCustody.detect,
                     legacy_inventory: nil)
        @database = database
        @state_home = File.expand_path(state_home)
        @process_identity = process_identity
        @custody = custody
        @legacy_inventory = legacy_inventory || method(:known_legacy_processes)
      end

      def call
        rows = @database.read do |db|
          {
            reservations: db[:launch_reservations].where(state: "reserved").all,
            processes: db[:owned_processes].exclude(state: "stopped").all,
            attempts: db[:attempts].where(state: %w[launching running]).all
          }
        end
        return refusal("unresolved_launch_reservation", rows[:reservations]) unless rows[:reservations].empty?

        registered_attempt_ids = rows[:processes].filter_map { |row| row[:attempt_id] }.uniq
        unregistered_attempts = rows[:attempts].reject do |attempt|
          registered_attempt_ids.include?(attempt.fetch(:attempt_id))
        end
        return refusal("unregistered_attempt_root", unregistered_attempts) unless unregistered_attempts.empty?

        attempt_roots = rows[:processes].select { |row| !row[:attempt_id].to_s.empty? }
        unless attempt_roots.empty?
          unless @custody.available? && attempt_roots.all? { |row| @custody.verifiable?(row) }
            return refusal("agent_attempt_root", attempt_roots)
          end
        end

        unsafe = rows[:processes].reject do |row|
          !row[:attempt_id].to_s.empty? ||
            (row.fetch(:proven_child_safe) == 1 && LaunchCoverage.proven_child_safe?(row.fetch(:origin)))
        end
        return refusal("unproven_launch_surface", unsafe) unless unsafe.empty?

        identities = rows[:processes].reject do |row|
          @process_identity.status(identity_hash(row)) == :matching
        end
        return refusal("process_identity_unverifiable", identities) unless identities.empty?

        registered_pids = rows[:processes].filter_map { |row| row[:pid] }
        legacy = @legacy_inventory.call.reject { |entry| registered_pids.include?(entry["pid"]) }
        return refusal("legacy_process_unregistered", legacy) unless legacy.empty?

        mode = attempt_roots.empty? ? "registered_only" : "delegated_cgroup_v2"
        CapabilityVerdict.new(
          eligible: true, reason: nil, ownership_mode: mode, disqualifying_inventory: []
        )
      rescue RuntimeControlPlane::Error => error
        refusal(error.code.to_s, [ { "error" => error.message } ])
      end

      private

      def refusal(reason, rows)
        CapabilityVerdict.new(
          eligible: false, reason: reason, ownership_mode: @custody.mode,
          disqualifying_inventory: Array(rows).map { |row| normalize_inventory(row) }
        )
      end

      def normalize_inventory(row)
        row.to_h.each_with_object({}) do |(key, value), result|
          next if %i[custody_evidence_json].include?(key)
          result[key.to_s] = value
        end
      end

      def identity_hash(row)
        {
          "pid" => row[:pid], "start_fingerprint" => row[:start_fingerprint],
          "session_id" => row[:session_id], "process_group_id" => row[:process_group_id]
        }
      end

      def known_legacy_processes
        paths = %w[.daemon.pid .bot.pid .babysitter.pid].map { |name| File.join(@state_home, name) }
        entries = paths.filter_map do |path|
          next unless File.file?(path) && !File.symlink?(path)
          payload = YAML.safe_load(File.read(path), permitted_classes: [ Time ], aliases: false)
          pid = Integer(payload["pid"], exception: false) if payload.is_a?(Hash)
          unless pid
            next({
              "service_identity" => File.basename(path), "pid" => nil,
              "unknown_reason" => "pid_receipt_unreadable"
            })
          end
          identity = @process_identity.capture(pid)
          identity ? identity.to_h.merge("service_identity" => File.basename(path)) : {
            "service_identity" => File.basename(path), "pid" => pid,
            "unknown_reason" => "process_identity_unavailable"
          }
        rescue Psych::Exception, SystemCallError, IOError
          { "service_identity" => File.basename(path), "pid" => nil, "unknown_reason" => "pid_receipt_unreadable" }
        end
        supervisor_pid = Integer(ENV["HIVEBOX_SUPERVISOR_PID"], exception: false)
        supervisor = supervisor_pid && @process_identity.capture(supervisor_pid)
        if supervisor
          entries << supervisor.to_h.merge("service_identity" => "hivebox_supervisor")
        elsif supervisor_pid
          entries << {
            "service_identity" => "hivebox_supervisor", "pid" => supervisor_pid,
            "unknown_reason" => "process_identity_unavailable"
          }
        end
        entries
      end
    end
  end
end
