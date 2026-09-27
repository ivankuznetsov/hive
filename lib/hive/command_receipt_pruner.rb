# frozen_string_literal: true

require "securerandom"
require "socket"
require "hive/command_maintenance_authority"
require "hive/command_operation"
require "hive/command_receipt_capacity"
require "hive/project_identity"
require "hive/runtime_control_plane"
require "hive/lock"

module Hive
  class CommandReceiptPruner
    RETENTION_SECONDS = 30 * 24 * 60 * 60
    ADMINISTRATIVE_RETENTION_SECONDS = RETENTION_SECONDS
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 1_000
    WARNING_BAND_PERCENT = 70
    ACTION_BAND_PERCENT = 85

    def initialize(database: Hive::RuntimeControlPlane.database, authority: nil,
                   clock: -> { Time.now.utc })
      @database = database
      @authority = authority
      @clock = clock
    end

    def preview(project_root: nil, namespace_id: nil, limit: DEFAULT_LIMIT, cursor: nil)
      bounded = bounded_limit(limit)
      fixed_cutoff = cutoff
      @database.read_only do |connection|
        authority(connection)
        selected = resolve_namespace_read_only(
          connection, project_root: project_root, namespace_id: namespace_id
        )
        unenrolled_project = !project_root.nil? && selected.nil?
        if unenrolled_project
          return {
            "schema" => "hive-receipt-prune", "schema_version" => 1, "ok" => true,
            "preview" => true, "confirmed" => false, "namespace_id" => nil,
            "cutoff" => timestamp(fixed_cutoff), "candidate_count" => 0,
            "candidates" => [], "project_enrollment" => "absent",
            "warning_band_percent" => WARNING_BAND_PERCENT,
            "action_band_percent" => ACTION_BAND_PERCENT
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
          connection, selected, rows, confirmed: false, fixed_cutoff: fixed_cutoff,
          identity_cursor: cursor, identity_limit: bounded
        )
      end
    rescue Sequel::DatabaseLockTimeout, SQLite3::BusyException => error
      maintenance_failure!(:command_prune_busy,
                           "resolve database contention, then rerun; free disk if storage is exhausted", error)
    rescue Errno::ENOSPC, Errno::EDQUOT => error
      maintenance_failure!(:command_prune_storage_unavailable, "free disk, then rerun", error)
    rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
      if sqlite_busy_error?(error)
        maintenance_failure!(:command_prune_busy,
                             "resolve database contention, then rerun; free disk if storage is exhausted", error)
      else
        maintenance_failure!(:command_prune_preview_unavailable,
                             "restore normal database availability before preview", error)
      end
    end

    def prune(project_root: nil, namespace_id: nil, limit: DEFAULT_LIMIT)
      selected = resolve_namespace(project_root: project_root, namespace_id: namespace_id, write: true)
      raise Hive::UsageError, "confirmed prune requires --project or --namespace-id" unless selected
      bounded = bounded_limit(limit)
      fixed_cutoff = cutoff
      context = Hive::CommandOperation.current_context
      batch_id = SecureRandom.uuid
      candidates = []
      recovered_outcomes = nil
      owner_process_start = Hive::Lock.process_start_time(Process.pid) ||
        raise(Hive::ConfigError, "cannot record prune owner process start time")

      @database.transaction do |connection|
        prune_completed_batches!(connection)
        owned_batch = if context
          connection[:command_maintenance_batches][administrative_receipt_id: context.receipt_id]
        end
        if owned_batch&.fetch(:state) == "completed"
          authority.authorize!(owned_batch.fetch(:principal))
          batch_id = owned_batch.fetch(:batch_id)
          selected = owned_batch.fetch(:namespace_id)
          fixed_cutoff = Hive::RuntimeControlPlane::Codec.load_time(owned_batch.fetch(:fixed_cutoff))
          candidates = JSON.parse(owned_batch.fetch(:candidates_json), symbolize_names: true)
          recovered_outcomes = JSON.parse(owned_batch.fetch(:outcomes_json))
          next
        end
        busy = connection[:command_maintenance_batches]
          .where(state: %w[prepared executing]).first
        if busy && context && busy[:administrative_receipt_id] == context.receipt_id
          batch_id = busy.fetch(:batch_id)
          selected = busy.fetch(:namespace_id)
          fixed_cutoff = Hive::RuntimeControlPlane::Codec.load_time(busy.fetch(:fixed_cutoff))
          candidates = JSON.parse(busy.fetch(:candidates_json), symbolize_names: true)
          next
        end
        if busy
          message = if authority.installation_owner? || busy.fetch(:principal) == authority.principal
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
          batch_id: batch_id, namespace_id: selected,
          administrative_receipt_id: context&.receipt_id, principal: authority.principal,
          principal_scope: authority.installation_owner? ? "installation" : "own",
          kind: "prune", state: "executing", generation: 1,
          owner_host: Socket.gethostname, owner_pid: Process.pid,
          owner_process_start: owner_process_start,
          fixed_cutoff: timestamp(fixed_cutoff),
          candidates_json: codec(candidates.map { |row| candidate_identity(row) }),
          outcomes_json: "[]", created_at: now, updated_at: now
        )
      end

      if recovered_outcomes
        return @database.read do |connection|
          preview_payload(
            connection, selected, candidates, confirmed: true, outcomes: recovered_outcomes,
            batch_id: batch_id, fixed_cutoff: fixed_cutoff
          )
        end
      end

      outcomes = delete_candidates(batch_id, selected, candidates, fixed_cutoff)
      @database.read do |connection|
        preview_payload(
          connection, selected, candidates, confirmed: true, outcomes: outcomes,
          batch_id: batch_id, fixed_cutoff: fixed_cutoff
        )
      end
    rescue Sequel::DatabaseLockTimeout, SQLite3::BusyException => error
      maintenance_failure!(:command_prune_busy,
                           "resolve database contention, then rerun; free disk if storage is exhausted", error)
    rescue Sequel::DatabaseError, SQLite3::Exception, Errno::ENOSPC, Errno::EDQUOT,
           SystemCallError, IOError => error
      if sqlite_busy_error?(error)
        maintenance_failure!(:command_prune_busy,
                             "resolve database contention, then rerun; free disk if storage is exhausted", error)
      else
        maintenance_failure!(:command_prune_storage_unavailable, "free disk, then rerun", error)
      end
    end

    private

    def resolve_namespace_read_only(connection, project_root:, namespace_id:)
      if project_root && namespace_id
        raise Hive::UsageError, "--project and --namespace-id are mutually exclusive"
      end
      if namespace_id
        require_installation_owner!
        row = connection[:command_namespaces][namespace_id: namespace_id]
        raise Hive::UsageError, "unknown command namespace #{namespace_id}" unless row
        return row.fetch(:namespace_id)
      end
      return unless project_root
      Hive::ProjectIdentity.resolve_read_only(
        project_root: project_root, connection: connection
      )&.namespace_id
    end

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
        .where(namespace_id: namespace_id, state: Hive::CommandReceiptStore::TERMINAL_STATES)
        .then { |dataset| authority.installation_owner? ? dataset : dataset.where(principal: authority.principal) }
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
      rows.each { |row| authority.authorize!(row.fetch(:principal)) }
    end

    def delete_candidates(batch_id, namespace_id, candidates, fixed_cutoff)
      batch = @database.read { |connection| connection[:command_maintenance_batches][batch_id: batch_id] }
      outcomes = JSON.parse(batch.fetch(:outcomes_json))
      expected_generation = batch.fetch(:generation)
      completed_ids = outcomes.filter_map do |outcome|
        outcome["receipt_id"] if outcome["outcome"] == "deleted"
      end
      candidates = candidates.reject { |candidate| completed_ids.include?(candidate.fetch(:receipt_id)) }
      candidates.each_slice(DEFAULT_LIMIT) do |slice|
        @database.transaction do |connection|
          current_batch = connection[:command_maintenance_batches][batch_id: batch_id]
          unless current_batch && current_batch.fetch(:state) == "executing" &&
                 current_batch.fetch(:generation) == expected_generation
            raise Hive::CommandConflict, "prune batch ownership changed before deletion"
          end
          authority.authorize!(current_batch.fetch(:principal))
          slice.each do |candidate|
            row = connection[:command_receipts][receipt_id: candidate.fetch(:receipt_id)]
            outcome = "skipped"
            if row && row.fetch(:generation) == candidate.fetch(:generation) &&
               row.fetch(:namespace_id) == namespace_id &&
               Hive::CommandReceiptStore::TERMINAL_STATES.include?(row.fetch(:state)) &&
               valid_terminal_time?(row[:terminal_at], fixed_cutoff) &&
               !connection[:command_receipt_pins]
                 .where(receipt_id: row.fetch(:receipt_id), lifecycle_status: "active").any?
              authority.authorize!(row.fetch(:principal))
              receipt_id = row.fetch(:receipt_id)
              logical_bytes = receipt_storage_bytes(connection, row)
              connection[:command_maintenance_audit].where(receipt_id: receipt_id).delete
              connection[:command_effects].where(receipt_id: receipt_id).delete
              connection[:command_dispatch_contexts].where(receipt_id: receipt_id).delete
              connection[:command_receipt_pins].where(receipt_id: receipt_id).delete
              connection[:command_successor_allocations]
                .where(predecessor_receipt_id: receipt_id).delete
              connection[:command_successor_allocations]
                .where(successor_receipt_id: receipt_id).delete
              connection[:command_receipts].where(
                receipt_id: receipt_id, generation: row.fetch(:generation)
              ).delete
              connection[:command_capacity].where(namespace_id: namespace_id).update(
                logical_bytes: Sequel.function(
                  :max, Sequel[:logical_bytes] - logical_bytes, 0
                ),
                revision: Sequel[:revision] + 1,
                updated_at: timestamp
              )
              outcome = "deleted"
            end
            identity = candidate_identity(candidate)
            outcomes.reject! { |existing| existing["receipt_id"] == identity["receipt_id"] }
            outcomes << identity.merge("outcome" => outcome)
          end
          now = timestamp
          changed = connection[:command_maintenance_batches].where(
            batch_id: batch_id, state: "executing", generation: expected_generation
          )
            .update(outcomes_json: codec(outcomes), generation: Sequel[:generation] + 1,
                    updated_at: now)
          raise Hive::CommandConflict, "prune batch changed during deletion" unless changed == 1
        end
        expected_generation += 1
      end
      @database.transaction do |connection|
        now = timestamp
        changed = connection[:command_maintenance_batches].where(
          batch_id: batch_id, state: "executing", generation: expected_generation
        )
          .update(state: "completed", generation: Sequel[:generation] + 1,
                  outcomes_json: codec(outcomes), updated_at: now, completed_at: now)
        raise Hive::CommandConflict, "prune batch changed before completion" unless changed == 1
      end
      outcomes
    end

    def preview_payload(connection, namespace_id, rows, confirmed:, fixed_cutoff:,
                        outcomes: nil, batch_id: nil, identity_cursor: nil,
                        identity_limit: DEFAULT_LIMIT)
      namespace_capacity = if authority.installation_owner?
        connection[:command_capacity][namespace_id: namespace_id]
      else
        principal_utilization(connection, namespace_id, authority.principal)
      end
      installation = connection[:command_capacity].select do
        [ sum(:nonterminal_count).as(:n), sum(:executing_count).as(:a), sum(:logical_bytes).as(:bytes) ]
      end.first
      namespace = connection[:command_namespaces][namespace_id: namespace_id]
      payload = {
        "schema" => "hive-receipt-prune", "schema_version" => 1, "ok" => true,
        "preview" => !confirmed, "confirmed" => confirmed,
        "namespace_id" => namespace_id, "cutoff" => timestamp(fixed_cutoff),
        "keyed_intake_enabled" => namespace&.fetch(:keyed_intake_enabled, 0) == 1,
        "candidate_count" => rows.length,
        "candidates" => rows.map { |row| candidate_identity(row) },
        "namespace_utilization" => utilization(
          namespace_capacity,
          limits: {
            nonterminal_count: namespace&.fetch(:nonterminal_limit, nil),
            executing_count: namespace&.fetch(:concurrency_limit, nil),
            logical_bytes: namespace&.fetch(:byte_admission_limit, nil)
          }
        ),
        "warning_band_percent" => WARNING_BAND_PERCENT,
        "action_band_percent" => ACTION_BAND_PERCENT
      }
      if authority.installation_owner?
        global = Hive::CommandReceiptCapacity.global_receipts
        physical = physical_utilization(connection)
        payload["installation_utilization"] = utilization(
          {
          "nonterminal_count" => installation.fetch(:n).to_i,
          "executing_count" => installation.fetch(:a).to_i,
          "logical_bytes" => installation.fetch(:bytes).to_i,
          "occupied_bytes" => physical.fetch("occupied_bytes")
          },
          limits: {
            nonterminal_count: global.fetch(
              "installation_nonterminal_limit",
              Hive::CommandReceiptCapacity::DEFAULT_INSTALLATION_NONTERMINAL_LIMIT
            ),
            executing_count: global.fetch(
              "installation_concurrency_limit",
              Hive::CommandReceiptCapacity::DEFAULT_INSTALLATION_CONCURRENCY_LIMIT
            ),
            occupied_bytes: global.fetch(
              "installation_byte_admission_limit",
              Hive::CommandReceiptCapacity::DEFAULT_INSTALLATION_BYTE_LIMIT
            )
          }
        ).merge(physical)
      else
        payload["installation_pressure"] = "ask_installation_owner"
      end
      payload.merge!(maintenance_identities(
        connection, namespace_id, limit: identity_limit, cursor: identity_cursor
      ))
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
            "keyed_intake_enabled" => row.fetch(:keyed_intake_enabled) == 1,
            "configured_limits" => {
              "nonterminal_count" => row.fetch(:nonterminal_limit),
              "executing_count" => row.fetch(:concurrency_limit),
              "logical_bytes" => row.fetch(:byte_admission_limit)
            }
          }.merge(utilization(
            capacity,
            limits: {
              nonterminal_count: row.fetch(:nonterminal_limit),
              executing_count: row.fetch(:concurrency_limit),
              logical_bytes: row.fetch(:byte_admission_limit)
            }
          )).merge(
            maintenance_identities(connection, row.fetch(:namespace_id), limit: DEFAULT_LIMIT)
          )
        end,
        "next_cursor" => more ? rows.last.fetch(:namespace_id) : nil,
        "warning_band_percent" => WARNING_BAND_PERCENT,
        "action_band_percent" => ACTION_BAND_PERCENT
      }
    end

    def utilization(row, limits: {})
      values = {
        "nonterminal_count" => value_from(row, :nonterminal_count).to_i,
        "executing_count" => value_from(row, :executing_count).to_i,
        "logical_bytes" => value_from(row, :logical_bytes).to_i
      }
      occupied = value_from(row, :occupied_bytes)
      values["occupied_bytes"] = occupied.to_i unless occupied.nil?
      values["limits"] = limits.transform_keys(&:to_s)
      values["percent"] = limits.each_with_object({}) do |(key, limit), result|
        next unless limit.to_i.positive?
        result[key.to_s] = ((values.fetch(key.to_s, 0).to_f / limit) * 100).round(2)
      end
      values["pressure_band"] = pressure_band(values.fetch("percent").values.max.to_f)
      values
    end

    def value_from(row, key)
      return unless row.respond_to?(:key?)
      return row[key] if row.key?(key)
      row[key.to_s] if row.key?(key.to_s)
    end

    def pressure_band(percent)
      return "action" if percent >= ACTION_BAND_PERCENT
      return "warning" if percent >= WARNING_BAND_PERCENT
      "normal"
    end

    def physical_utilization(connection)
      page_size = pragma_integer(connection, "page_size")
      page_count = pragma_integer(connection, "page_count")
      freelist_count = pragma_integer(connection, "freelist_count")
      wal_bytes = File.exist?("#{@database.path}-wal") ? File.size("#{@database.path}-wal") : 0
      {
        "page_size" => page_size, "page_count" => page_count,
        "freelist_count" => freelist_count,
        "occupied_main_bytes" => (page_count - freelist_count) * page_size,
        "wal_bytes" => wal_bytes,
        "occupied_bytes" => ((page_count - freelist_count) * page_size) + wal_bytes
      }
    end

    def pragma_integer(connection, name)
      Integer(connection.fetch("PRAGMA #{name}").first.values.first)
    end

    def candidate_identity(row)
      { "receipt_id" => row.fetch(:receipt_id), "generation" => row.fetch(:generation) }
    end

    def receipt_storage_bytes(connection, row)
      receipt_id = row.fetch(:receipt_id)
      total = Hive::CommandReceiptCapacity.receipt_logical_bytes(row)
      total += connection[:command_effects].where(receipt_id: receipt_id).all.sum do |effect|
        effect[:identity_json].to_s.bytesize + effect[:evidence_json].to_s.bytesize + 512
      end
      total += connection[:command_receipt_pins].where(receipt_id: receipt_id).count * 512
      total += connection[:command_maintenance_audit].where(receipt_id: receipt_id).all.sum do |audit|
        audit[:evidence_json].to_s.bytesize + 512
      end
      total += connection[:command_dispatch_contexts].where(receipt_id: receipt_id).count * 512
      total += connection[:command_successor_allocations]
        .where(predecessor_receipt_id: receipt_id).count * 512
      total
    end

    def principal_utilization(connection, namespace_id, principal)
      rows = connection[:command_receipts].where(
        namespace_id: namespace_id, principal: principal
      ).all
      {
        nonterminal_count: rows.count { |row|
          Hive::CommandReceiptCapacity.counts_receipt?(row) &&
            Hive::CommandReceiptStore::NONTERMINAL_STATES.include?(row.fetch(:state))
        },
        executing_count: rows.count { |row|
          Hive::CommandReceiptCapacity.counts_receipt?(row) && row.fetch(:state) == "executing"
        },
        logical_bytes: rows.sum { |row| receipt_storage_bytes(connection, row) }
      }
    end

    def maintenance_identities(connection, namespace_id, limit:, cursor: nil)
      receipts = connection[:command_receipts].where(namespace_id: namespace_id)
      receipts = receipts.where(principal: authority.principal) unless authority.installation_owner?
      receipt_ids = receipts.select(:receipt_id)
      cursor_kind, cursor_id = cursor.to_s.split(":", 2) if cursor
      sources = [
        [ "batch", :batch_id, connection[:command_maintenance_batches]
          .where(namespace_id: namespace_id, state: %w[prepared executing])
          .then { |dataset|
            authority.installation_owner? ? dataset : dataset.where(principal: authority.principal)
          } ],
        [ "pin", :pin_id, connection[:command_receipt_pins]
          .where(receipt_id: receipt_ids, lifecycle_status: "active") ],
        [ "receipt", :receipt_id, receipts
          .where(state: Hive::CommandReceiptStore::NONTERMINAL_STATES) ]
      ]
      identities = sources.each_with_object([]) do |(kind, id_column, dataset), rows|
        next if cursor_kind && kind < cursor_kind
        scoped = dataset
        scoped = scoped.where { Sequel[id_column] > cursor_id.to_s } if cursor_kind == kind
        remaining = limit + 1 - rows.length
        break rows unless remaining.positive?
        rows.concat(scoped.order(id_column).limit(remaining)
          .select_map([ id_column, :generation ])
          .map { |id, generation| [ kind, id, generation ] })
      end
      more = identities.length > limit
      page = identities.first(limit)
      grouped = page.group_by(&:first)
      {
        "nonterminal_receipts" => Array(grouped["receipt"]).map {
          |_kind, id, generation| { "receipt_id" => id, "generation" => generation }
        },
        "active_pins" => Array(grouped["pin"]).map {
          |_kind, id, generation| { "pin_id" => id, "generation" => generation }
        },
        "unfinished_batches" => Array(grouped["batch"]).map {
          |_kind, id, generation| { "batch_id" => id, "generation" => generation }
        },
        "maintenance_next_cursor" => more ? "#{page.last[0]}:#{page.last[1]}" : nil
      }
    end

    def bounded_limit(value)
      limit = Integer(value || DEFAULT_LIMIT)
      raise Hive::UsageError, "--limit must be between 1 and #{MAX_LIMIT}" unless limit.between?(1, MAX_LIMIT)
      limit
    rescue ArgumentError, TypeError
      raise Hive::UsageError, "--limit must be between 1 and #{MAX_LIMIT}"
    end

    def require_installation_owner!
      return if authority.installation_owner?
      raise Hive::ConfigError, "installation-wide receipt preview requires the installation owner"
    end

    def authority(connection = nil)
      @authority ||= begin
        principal = if connection
          installation = connection[:installations].first&.fetch(:installation_id)
          raise Hive::ConfigError, "runtime installation identity is missing" unless installation
          "installation:#{installation}:uid:#{Process.uid}"
        else
          Hive::CommandOperation.local_principal(@database)
        end
        Hive::CommandMaintenanceAuthority.local(principal: principal)
      end
    end

    def prune_completed_batches!(connection)
      threshold = timestamp(@clock.call.utc - ADMINISTRATIVE_RETENTION_SECONDS)
      batches = connection[:command_maintenance_batches]
        .where(state: %w[completed abandoned]).where { completed_at < threshold }.all
      batches.select! { |batch|
        receipt_id = batch[:administrative_receipt_id]
        receipt = receipt_id && connection[:command_receipts][receipt_id: receipt_id]
        receipt.nil? || Hive::CommandReceiptStore::TERMINAL_STATES.include?(receipt[:state])
      }
      batches.select! { |batch|
        authority.installation_owner? || batch.fetch(:principal) == authority.principal
      }
      batches.each do |batch|
        authority.authorize!(batch.fetch(:principal))
        audits = connection[:command_maintenance_audit].where(batch_id: batch.fetch(:batch_id)).all
        connection[:command_maintenance_audit].where(batch_id: batch.fetch(:batch_id)).delete
        connection[:command_maintenance_batches].where(batch_id: batch.fetch(:batch_id)).delete
        bytes = audits.sum { |audit| audit[:evidence_json].to_s.bytesize + 512 }
        next if bytes.zero? || batch[:namespace_id].to_s.empty?
        connection[:command_capacity].where(namespace_id: batch.fetch(:namespace_id)).update(
          logical_bytes: Sequel.function(:max, Sequel[:logical_bytes] - bytes, 0),
          revision: Sequel[:revision] + 1, updated_at: timestamp
        )
      end
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

    def sqlite_busy_error?(error)
      current = error
      while current
        return true if current.is_a?(SQLite3::BusyException)
        current = current.cause
      end
      false
    end
  end
end
