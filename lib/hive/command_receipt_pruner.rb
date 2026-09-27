# frozen_string_literal: true

require "securerandom"
require "socket"
require "hive/command_maintenance_authority"
require "hive/command_operation"
require "hive/project_identity"
require "hive/runtime_control_plane"

module Hive
  class CommandReceiptPruner
    RETENTION_SECONDS = 30 * 24 * 60 * 60
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 1_000

    def initialize(database: Hive::RuntimeControlPlane.database, authority: nil,
                   clock: -> { Time.now.utc })
      @database = database
      @authority = authority || Hive::CommandMaintenanceAuthority.local(
        principal: Hive::CommandOperation.local_principal(database)
      )
      @clock = clock
    end

    def preview(project_root: nil, namespace_id: nil, limit: DEFAULT_LIMIT, cursor: nil)
      bounded = bounded_limit(limit)
      selected = resolve_namespace(project_root: project_root, namespace_id: namespace_id, write: false)
      unenrolled_project = !project_root.nil? && selected.nil?
      fixed_cutoff = cutoff
      @database.read_only do |connection|
        if unenrolled_project
          return {
            "schema" => "hive-receipt-prune", "schema_version" => 1, "ok" => true,
            "preview" => true, "confirmed" => false, "namespace_id" => nil,
            "cutoff" => timestamp(fixed_cutoff), "candidate_count" => 0,
            "candidates" => [], "project_enrollment" => "absent"
          }
        end
        if selected.nil?
          require_installation_owner!
          return namespace_preview(
            connection, limit: bounded, cursor: cursor, fixed_cutoff: fixed_cutoff
          )
        end

        rows = eligible_rows(connection, selected, cutoff: fixed_cutoff, limit: bounded)
        authorize_rows!(rows)
        preview_payload(
          connection, selected, rows, confirmed: false, fixed_cutoff: fixed_cutoff
        )
      end
    rescue Sequel::DatabaseLockTimeout => error
      maintenance_failure!(:command_prune_busy,
                           "resolve database contention, then rerun; free disk if storage is exhausted", error)
    rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
      maintenance_failure!(:command_prune_preview_unavailable,
                           "restore normal database availability before preview", error)
    end

    def prune(project_root: nil, namespace_id: nil, limit: DEFAULT_LIMIT)
      selected = resolve_namespace(project_root: project_root, namespace_id: namespace_id, write: true)
      raise Hive::UsageError, "confirmed prune requires --project or --namespace-id" unless selected
      bounded = bounded_limit(limit)
      fixed_cutoff = cutoff
      batch_id = SecureRandom.uuid
      candidates = []

      @database.transaction do |connection|
        busy = connection[:command_maintenance_batches]
          .where(state: %w[prepared executing]).first
        if busy
          message = if @authority.installation_owner? || busy.fetch(:principal) == @authority.principal
            "another prune batch #{busy.fetch(:batch_id)} generation #{busy.fetch(:generation)} is unfinished; " \
              "resume it or use hive receipt abandon-batch"
          else
            "another prune batch is unfinished; ask the installation owner to recover it"
          end
          raise Hive::CommandCapacityError.new(
            message, reason: :command_prune_busy, scope: :installation
          )
        end
        candidates = eligible_rows(connection, selected, cutoff: fixed_cutoff, limit: bounded)
        authorize_rows!(candidates)
        now = timestamp
        connection[:command_maintenance_batches].insert(
          batch_id: batch_id, namespace_id: selected, principal: @authority.principal,
          principal_scope: @authority.installation_owner? ? "installation" : "own",
          kind: "prune", state: "executing", generation: 1,
          owner_host: Socket.gethostname, owner_pid: Process.pid,
          fixed_cutoff: timestamp(fixed_cutoff),
          candidates_json: codec(candidates.map { |row| candidate_identity(row) }),
          outcomes_json: "[]", created_at: now, updated_at: now
        )
      end

      outcomes = delete_candidates(batch_id, selected, candidates, fixed_cutoff)
      @database.read do |connection|
        preview_payload(
          connection, selected, candidates, confirmed: true, outcomes: outcomes,
          batch_id: batch_id, fixed_cutoff: fixed_cutoff
        )
      end
    rescue Sequel::DatabaseLockTimeout => error
      maintenance_failure!(:command_prune_busy,
                           "resolve database contention, then rerun; free disk if storage is exhausted", error)
    rescue Sequel::DatabaseError, SQLite3::Exception, Errno::ENOSPC, Errno::EDQUOT,
           SystemCallError, IOError => error
      maintenance_failure!(:command_prune_storage_unavailable, "free disk, then rerun", error)
    end

    private

    def resolve_namespace(project_root:, namespace_id:, write:)
      if project_root && namespace_id
        raise Hive::UsageError, "--project and --namespace-id are mutually exclusive"
      end
      if namespace_id
        require_installation_owner!
        row = @database.read { |connection| connection[:command_namespaces][namespace_id: namespace_id] }
        raise Hive::UsageError, "unknown command namespace #{namespace_id}" unless row
        return row.fetch(:namespace_id)
      end
      return unless project_root

      identity = Hive::ProjectIdentity.resolve(
        project_root: project_root, database: @database, create: false
      )
      return nil if identity.nil? && !write
      raise Hive::ConfigError, "project has no command namespace" unless identity
      identity.namespace_id
    end

    def eligible_rows(connection, namespace_id, cutoff:, limit:)
      cutoff_value = timestamp(cutoff)
      connection[:command_receipts]
        .where(namespace_id: namespace_id, state: %w[succeeded failed settled])
        .where { terminal_at < cutoff_value }
        .exclude(receipt_id: connection[:command_receipt_pins]
          .where(lifecycle_status: "active").select(:receipt_id))
        .order(:terminal_at, :receipt_id).limit(limit).all
        .select { |row| valid_terminal_time?(row[:terminal_at], cutoff) }
    end

    def valid_terminal_time?(value, before)
      Hive::RuntimeControlPlane::Codec.load_time(value) < before
    rescue Hive::RuntimeControlPlane::CodecError
      false
    end

    def authorize_rows!(rows)
      rows.each { |row| @authority.authorize!(row.fetch(:principal)) }
    end

    def delete_candidates(batch_id, namespace_id, candidates, fixed_cutoff)
      outcomes = []
      candidates.each_slice(DEFAULT_LIMIT) do |slice|
        @database.transaction do |connection|
          slice.each do |candidate|
            row = connection[:command_receipts][receipt_id: candidate.fetch(:receipt_id)]
            outcome = "skipped"
            if row && row.fetch(:generation) == candidate.fetch(:generation) &&
               row.fetch(:namespace_id) == namespace_id &&
               %w[succeeded failed settled].include?(row.fetch(:state)) &&
               valid_terminal_time?(row[:terminal_at], fixed_cutoff) &&
               !connection[:command_receipt_pins]
                 .where(receipt_id: row.fetch(:receipt_id), lifecycle_status: "active").any?
              @authority.authorize!(row.fetch(:principal))
              receipt_id = row.fetch(:receipt_id)
              connection[:command_maintenance_audit].where(receipt_id: receipt_id).delete
              connection[:command_effects].where(receipt_id: receipt_id).delete
              connection[:command_dispatch_contexts].where(receipt_id: receipt_id).delete
              connection[:command_receipt_pins].where(receipt_id: receipt_id).delete
              connection[:command_successor_allocations]
                .where(predecessor_receipt_id: receipt_id).delete
              connection[:command_receipts].where(
                receipt_id: receipt_id, generation: row.fetch(:generation)
              ).delete
              logical_bytes = row.fetch(:frozen_request_json).bytesize + 1024
              connection[:command_capacity].where(namespace_id: namespace_id).update(
                logical_bytes: Sequel.function(
                  :max, Sequel[:logical_bytes] - logical_bytes, 0
                ),
                revision: Sequel[:revision] + 1,
                updated_at: timestamp
              )
              outcome = "deleted"
            end
            outcomes << candidate_identity(candidate).merge("outcome" => outcome)
          end
          now = timestamp
          connection[:command_maintenance_batches].where(batch_id: batch_id, state: "executing")
            .update(outcomes_json: codec(outcomes), generation: Sequel[:generation] + 1,
                    updated_at: now)
        end
      end
      @database.transaction do |connection|
        now = timestamp
        connection[:command_maintenance_batches].where(batch_id: batch_id, state: "executing")
          .update(state: "completed", generation: Sequel[:generation] + 1,
                  outcomes_json: codec(outcomes), updated_at: now, completed_at: now)
      end
      outcomes
    end

    def preview_payload(connection, namespace_id, rows, confirmed:, fixed_cutoff:,
                        outcomes: nil, batch_id: nil)
      namespace_capacity = connection[:command_capacity][namespace_id: namespace_id]
      installation = connection[:command_capacity].select do
        [ sum(:nonterminal_count).as(:n), sum(:executing_count).as(:a), sum(:logical_bytes).as(:bytes) ]
      end.first
      payload = {
        "schema" => "hive-receipt-prune", "schema_version" => 1, "ok" => true,
        "preview" => !confirmed, "confirmed" => confirmed,
        "namespace_id" => namespace_id, "cutoff" => timestamp(fixed_cutoff),
        "candidate_count" => rows.length,
        "candidates" => rows.map { |row| candidate_identity(row) },
        "namespace_utilization" => utilization(namespace_capacity),
        "warning_band_percent" => 70, "action_band_percent" => 85
      }
      if @authority.installation_owner?
        payload["installation_utilization"] = {
          "nonterminal_count" => installation.fetch(:n).to_i,
          "executing_count" => installation.fetch(:a).to_i,
          "logical_namespace_bytes" => installation.fetch(:bytes).to_i,
          "main_bytes" => File.size(@database.path),
          "wal_bytes" => File.exist?("#{@database.path}-wal") ? File.size("#{@database.path}-wal") : 0
        }
      else
        payload["installation_pressure"] = "ask_installation_owner"
      end
      payload["batch_id"] = batch_id if batch_id
      payload["outcomes"] = outcomes if outcomes
      payload
    end

    def namespace_preview(connection, limit:, cursor:, fixed_cutoff:)
      dataset = connection[:command_namespaces].order(:namespace_id)
      dataset = dataset.where { namespace_id > cursor.to_s } if cursor
      rows = dataset.limit(limit + 1).all
      more = rows.length > limit
      rows = rows.first(limit)
      {
        "schema" => "hive-receipt-prune", "schema_version" => 1, "ok" => true,
        "preview" => true, "confirmed" => false, "namespace_id" => nil,
        "cutoff" => timestamp(fixed_cutoff), "candidate_count" => 0, "candidates" => [],
        "namespaces" => rows.map do |row|
          capacity = connection[:command_capacity][namespace_id: row.fetch(:namespace_id)]
          {
            "namespace_id" => row.fetch(:namespace_id),
            "generation" => row.fetch(:enrollment_generation),
            "keyed_intake_enabled" => row.fetch(:keyed_intake_enabled) == 1
          }.merge(utilization(capacity))
        end,
        "next_cursor" => more ? rows.last.fetch(:namespace_id) : nil,
        "warning_band_percent" => 70, "action_band_percent" => 85
      }
    end

    def utilization(row)
      {
        "nonterminal_count" => row&.fetch(:nonterminal_count, 0).to_i,
        "executing_count" => row&.fetch(:executing_count, 0).to_i,
        "logical_bytes" => row&.fetch(:logical_bytes, 0).to_i
      }
    end

    def candidate_identity(row)
      { "receipt_id" => row.fetch(:receipt_id), "generation" => row.fetch(:generation) }
    end

    def bounded_limit(value)
      limit = Integer(value || DEFAULT_LIMIT)
      raise Hive::UsageError, "--limit must be between 1 and #{MAX_LIMIT}" unless limit.between?(1, MAX_LIMIT)
      limit
    rescue ArgumentError, TypeError
      raise Hive::UsageError, "--limit must be between 1 and #{MAX_LIMIT}"
    end

    def require_installation_owner!
      return if @authority.installation_owner?
      raise Hive::ConfigError, "installation-wide receipt preview requires the installation owner"
    end

    def cutoff = @clock.call.utc - RETENTION_SECONDS
    def timestamp(value = @clock.call.utc) = Hive::RuntimeControlPlane::Codec.dump_time(value)
    def codec(value) = Hive::RuntimeControlPlane::Codec.dump_json(value)

    def maintenance_failure!(reason, remedy, error)
      raise error if error.is_a?(Hive::CommandCapacityError)
      raise Hive::CommandCapacityError.new(
        "#{reason.to_s.tr('_', ' ')}: #{remedy} (#{error.class}: #{error.message})",
        reason: reason, scope: :installation
      )
    end
  end
end
