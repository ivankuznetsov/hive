# frozen_string_literal: true

module Hive
  module CommandReceiptStoreReclamation
    private

    def reclaim_dead_executing_owners(trigger_claim, scope:)
      authority = @maintenance_authority || Hive::CommandMaintenanceAuthority.local(
        principal: trigger_claim.principal
      )
      candidates, = database.read do |connection|
        namespace = connection[:command_namespaces][namespace_id: trigger_claim.namespace_id]
        cursor = if namespace[:reclamation_cursor_updated_at] &&
                    namespace[:reclamation_cursor_receipt_id]
          [ namespace.fetch(:reclamation_cursor_updated_at),
            namespace.fetch(:reclamation_cursor_receipt_id) ]
        end
        dataset = connection[:command_receipts].where(state: "executing")
        dataset = dataset.where(namespace_id: trigger_claim.namespace_id) if scope == "namespace"
        if cursor
          updated_at, receipt_id = cursor
          dataset = dataset.where {
            (Sequel[:updated_at] > updated_at) |
              ((Sequel[:updated_at] == updated_at) & (Sequel[:receipt_id] > receipt_id))
          }
        end
        rows = dataset.order(:updated_at, :receipt_id)
          .limit(Hive::CommandReceiptStore::MAX_RECLAMATION_PROBES_PER_ADMISSION).all
        if rows.empty? && cursor
          dataset = connection[:command_receipts].where(state: "executing")
          dataset = dataset.where(namespace_id: trigger_claim.namespace_id) if scope == "namespace"
          rows = dataset.order(:updated_at, :receipt_id)
            .limit(Hive::CommandReceiptStore::MAX_RECLAMATION_PROBES_PER_ADMISSION).all
        end
        [ rows, cursor ]
      end
      last = candidates.last
      database.transaction do |connection|
        connection[:command_namespaces].where(namespace_id: trigger_claim.namespace_id).update(
          reclamation_cursor_updated_at: last&.fetch(:updated_at),
          reclamation_cursor_receipt_id: last&.fetch(:receipt_id)
        )
      end
      proofs = candidates.filter_map do |row|
        begin
          authority.authorize!(row.fetch(:principal))
          Hive::CommandOwnerProof.dead(
            row, host: @host, alive: @alive, ownership: @ownership, clock: @clock
          )
        rescue Hive::Error, SystemCallError, IOError
          nil
        end
      end
      proofs.count { |row, proof| commit_automatic_reclamation(row, proof, authority, trigger_claim) }
    rescue Hive::ConfigError
      0
    end

    def commit_automatic_reclamation(row, proof, authority, trigger_claim)
      now = timestamp
      database.transaction do |connection|
        current = connection[:command_receipts][receipt_id: row.fetch(:receipt_id)]
        next false unless current && current.fetch(:state) == "executing" &&
                          current.fetch(:generation) == row.fetch(:generation) &&
                          %i[owner_host owner_pid owner_process_start].all? {
                            |key| current[key] == row[key]
                          }
        authority.authorize!(current.fetch(:principal))
        changed = connection[:command_receipts].where(
          receipt_id: row.fetch(:receipt_id), state: "executing",
          generation: row.fetch(:generation), owner_host: row.fetch(:owner_host),
          owner_pid: row.fetch(:owner_pid), owner_process_start: row.fetch(:owner_process_start)
        ).update(
          state: "unresolved", generation: row.fetch(:generation) + 1,
          typed_reason: "command_orphaned_owner", owner_token: nil, updated_at: now
        )
        next false unless changed == 1

        if capacity_counted?(row)
          connection[:command_capacity].where(namespace_id: row.fetch(:namespace_id)).update(
            executing_count: Sequel[:executing_count] - 1,
            revision: Sequel[:revision] + 1, updated_at: now
          )
        end
        Hive::CommandReceiptLedger.insert_audit!(connection,
          audit_id: SecureRandom.uuid, receipt_id: row.fetch(:receipt_id),
          namespace_id: row.fetch(:namespace_id), acting_principal: authority.principal,
          principal_source: authority.principal_source,
          authority_basis: authority.authority_basis, peer_address: authority.peer_address,
          action: "automatic_admission_orphan_reclassification",
          affected_principal: row.fetch(:principal),
          reason: "capacity admission for #{trigger_claim.receipt_id}",
          evidence_json: Hive::RuntimeControlPlane::Codec.dump_json(proof), created_at: now
        )
        add_logical_bytes!(
          connection, row.fetch(:namespace_id),
          Hive::RuntimeControlPlane::Codec.dump_json(proof).bytesize + 512
        )
        true
      end
    end
  end
end
