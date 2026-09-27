# frozen_string_literal: true

require "digest"
require "securerandom"
require "socket"
require "hive/command_mutations"
require "hive/command_maintenance_authority"
require "hive/command_owner_proof"
require "hive/command_receipt_capacity"
require "hive/pid_file"
require "hive/lock"
require "hive/project_identity"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/command_schema"

module Hive
  class CommandReceiptStore
    MAX_RESULT_BYTES = 256 * 1024
    MAX_RECLAMATION_PROBES_PER_ADMISSION = 4
    TERMINAL_STATES = %w[succeeded failed settled].freeze
    NONTERMINAL_STATES = %w[prepared executing unresolved aborted].freeze

    Claim = Data.define(
      :disposition, :receipt_id, :namespace_id, :generation, :state,
      :principal, :request_fingerprint, :result, :status, :reason, :public_receipt,
      :project_root
    )
    Pin = Data.define(
      :pin_id, :receipt_id, :principal, :intent_id, :intent_generation,
      :generation, :retry_horizon_expires_at, :lifecycle_status
    )

    def initialize(database: Hive::RuntimeControlPlane.database, maintenance_authority: nil,
                   alive: Hive::PidFile.method(:alive?),
                   ownership: Hive::PidFile.method(:ownership),
                   host: Socket.gethostname, clock: -> { Time.now.utc })
      @database = database
      @maintenance_authority = maintenance_authority
      @alive = alive
      @ownership = ownership
      @host = host
      @clock = clock
    end

    attr_reader :database

    def lookup_existing(project_root:, key:, command:, target:, request:, principal:)
      require_extension!
      identity = Hive::ProjectIdentity.resolve(
        project_root: project_root, database: database, create: false
      )
      return nil unless identity
      key_digest = Digest::SHA256.hexdigest(Hive::CommandMutations.normalize_key(key))
      row = database.read do |connection|
        connection[:command_receipts][
          namespace_id: identity.namespace_id, key_digest: key_digest
        ]
      end
      return nil unless row
      expected = Hive::CommandMutations.fingerprint(
        command: command, namespace_id: identity.namespace_id, target: target,
        principal: principal, options: request, display: {}
      )

      classify_existing!(
        row, principal: principal, request_fingerprint: expected, project_root: project_root
      )
    end

    # Look up a caller receipt across a bounded set of already-authorized
    # project roots. This is intentionally a replay-only path: it never enrolls
    # a project and never chooses a namespace for a fresh reservation. Command
    # adapters use it before resolving a mutable task folder so a moved or
    # deleted original selector cannot hide its durable result.
    def lookup_existing_in_projects(project_roots:, key:, command:, target:, request:, principal:)
      require_extension!
      roots = Array(project_roots).compact.map { |root| File.expand_path(root.to_s) }.uniq
      return nil if roots.empty?

      key_digest = Digest::SHA256.hexdigest(Hive::CommandMutations.normalize_key(key))
      matches = []
      conflicting = []
      roots.each do |root|
        identity = Hive::ProjectIdentity.resolve(
          project_root: root, database: database, create: false
        )
        next unless identity

        row = database.read do |connection|
          connection[:command_receipts][
            namespace_id: identity.namespace_id, key_digest: key_digest
          ]
        end
        next unless row

        expected = Hive::CommandMutations.fingerprint(
          command: command, namespace_id: identity.namespace_id, target: target,
          principal: principal, options: request, display: {}
        )
        if row.fetch(:principal) == principal.to_s &&
           row.fetch(:request_fingerprint) == expected
          matches << [ row, root ]
        else
          conflicting << [ row, root, expected ]
        end
      end

      if matches.length > 1
        raise Hive::CommandConflict,
              "idempotency key matches more than one registered project; pass --project"
      end
      if matches.one?
        row, root = matches.first
        return classify_existing!(
          row, principal: principal, request_fingerprint: row.fetch(:request_fingerprint),
          project_root: root
        )
      end
      if roots.one? && conflicting.one?
        row, root, expected = conflicting.first
        return classify_existing!(
          row, principal: principal, request_fingerprint: expected, project_root: root
        )
      end

      nil
    end

    def reserve(project_root:, key:, command:, target:, request:, principal:, mode: nil,
                principal_source: "injected", execute: false,
                maintenance: false,
                owner_host: Socket.gethostname, owner_pid: Process.pid,
                owner_process_start: nil)
      require_extension!
      normalized_key = Hive::CommandMutations.normalize_key(key)
      policy = Hive::CommandReceiptCapacity.load(project_root)
      identity = Hive::ProjectIdentity.resolve(
        project_root: project_root, database: database, create: false
      )
      if identity.nil?
        if maintenance
          raise Hive::ConfigError, "project has no command namespace for keyed maintenance"
        else
          intake_disabled! unless policy.keyed_intake_enabled
          identity = Hive::ProjectIdentity.resolve(
            project_root: project_root, database: database, create: true
          )
        end
      end
      key_digest = Digest::SHA256.hexdigest(normalized_key)
      request_fingerprint = Hive::CommandMutations.fingerprint(
        command: command, namespace_id: identity.namespace_id, target: target,
        principal: principal, options: request, display: {}
      )
      now = timestamp
      receipt_id = SecureRandom.uuid
      inserted = false
      capacity = Hive::CommandReceiptCapacity.new(database: database, policy: policy)
      owner_process_start ||= process_start(owner_pid) if execute
      attempts = 0
      begin
        attempts += 1
        row = database.transaction do |connection|
        existing = connection[:command_receipts][
          namespace_id: identity.namespace_id, key_digest: key_digest
        ]
        next existing if existing

        intake_disabled! unless policy.keyed_intake_enabled || maintenance
        unless maintenance
          capacity.admit_nonterminal!(
            connection, namespace_id: identity.namespace_id,
            request_bytes: logical_bytes(request),
            occupied_installation_bytes: capacity.occupied_installation_bytes(connection: connection)
          )
          capacity.admit_execution!(connection, namespace_id: identity.namespace_id) if execute
        end
        namespace_updates = {
          policy_revision: policy.revision[0, 15].to_i(16),
          nonterminal_limit: policy.nonterminal_limit,
          concurrency_limit: policy.concurrency_limit,
          byte_admission_limit: policy.byte_admission_limit,
          updated_at: now
        }
        namespace_updates[:keyed_intake_enabled] = 1 unless maintenance
        connection[:command_namespaces].where(namespace_id: identity.namespace_id).update(
          namespace_updates
        )

        connection[:command_receipts].insert(
          receipt_id: receipt_id,
          namespace_id: identity.namespace_id,
          key_digest: key_digest,
          principal: principal.to_s,
          principal_source: principal_source.to_s,
          command: command.to_s,
          mode: mode&.to_s,
          original_target: target.to_s,
          request_fingerprint: request_fingerprint,
          frozen_request_json: Hive::RuntimeControlPlane::Codec.dump_json(safe_request(request)),
          state: execute ? "executing" : "prepared",
          generation: 1,
          owner_host: execute ? owner_host : nil,
          owner_pid: execute ? owner_pid : nil,
          owner_process_start: execute ? (owner_process_start || process_start(owner_pid)) : nil,
          owner_token: execute ? SecureRandom.hex(16) : nil,
          retry_eligible: 0,
          created_at: now,
          updated_at: now
        )
        connection[:command_successor_allocations].where(
          namespace_id: identity.namespace_id, principal: principal.to_s,
          successor_key_identity: normalized_key, successor_receipt_id: nil
        ).update(successor_receipt_id: receipt_id)
        unless maintenance
          connection[:command_capacity].where(namespace_id: identity.namespace_id).update(
            nonterminal_count: Sequel[:nonterminal_count] + 1,
            executing_count: Sequel[:executing_count] + (execute ? 1 : 0),
            logical_bytes: Sequel[:logical_bytes] + logical_bytes(request),
            revision: Sequel[:revision] + 1,
            updated_at: now
          )
        end
        inserted = true
        connection[:command_receipts][receipt_id: receipt_id]
        end
      rescue Sequel::UniqueConstraintViolation
        retry if attempts < 2
        raise Hive::CommandConflict, "command receipt reservation conflicted repeatedly"
      rescue Hive::CommandCapacityError => error
        raise unless execute && error.reason == "command_concurrency_limit" && attempts < 2
        trigger = Claim.new(
          disposition: :new, receipt_id: "pending-admission", namespace_id: identity.namespace_id,
          generation: 0, state: "prepared", principal: principal.to_s,
          request_fingerprint: request_fingerprint, result: nil, status: nil, reason: nil,
          public_receipt: nil, project_root: project_root
        )
        raise unless reclaim_dead_executing_owners(trigger, scope: error.scope).positive?
        retry
      end

      return claim_from(row, :new, project_root: project_root) if inserted

      classify_existing!(
        row, principal: principal, request_fingerprint: request_fingerprint,
        project_root: project_root
      )
    end

    def mark_executing(claim, owner_host: Socket.gethostname, owner_pid: Process.pid,
                       owner_process_start: nil)
      owner_process_start ||= process_start(owner_pid)
      policy = Hive::CommandReceiptCapacity.load(claim.project_root)
      transition!(
        claim, from: "prepared", to: "executing",
        updates: {
          owner_host: owner_host, owner_pid: owner_pid,
          owner_process_start: owner_process_start, owner_token: SecureRandom.hex(16)
        }, executing_delta: 1, execution_policy: policy
      )
    rescue Hive::CommandCapacityError => error
      raise unless error.reason == "command_concurrency_limit"
      raise unless reclaim_dead_executing_owners(claim, scope: error.scope).positive?

      transition!(
        claim, from: "prepared", to: "executing",
        updates: {
          owner_host: owner_host, owner_pid: owner_pid,
          owner_process_start: owner_process_start, owner_token: SecureRandom.hex(16)
        }, executing_delta: 1, execution_policy: policy
      )
    end

    def resume_maintenance(claim, owner_host: Socket.gethostname, owner_pid: Process.pid,
                           owner_process_start: nil)
      owner_process_start ||= process_start(owner_pid)
      transition!(
        claim, from: "unresolved", to: "executing",
        updates: {
          owner_host: owner_host, owner_pid: owner_pid,
          owner_process_start: owner_process_start, owner_token: SecureRandom.hex(16)
        }
      )
    end

    def succeed(claim, result:, status: 0)
      finalize!(claim, state: "succeeded", result: result, status: status, reason: nil)
    end

    def fail_non_application(claim, result:, status:, reason:, whole_effect_non_application:)
      unless whole_effect_non_application == true
        raise Hive::CommandUnresolved.new(
          message: "retry eligibility requires proof of whole-effect non-application"
        )
      end
      finalize!(
        claim, state: "failed", result: result, status: status,
        reason: reason, retry_eligible: true
      )
    end

    def mark_unresolved(claim, reason:)
      transition!(
        claim, from: %w[prepared executing], to: "unresolved",
        updates: { typed_reason: reason.to_s },
        executing_delta: claim.state == "executing" ? -1 : 0
      )
    end

    def receipt(receipt_id)
      database.read { |connection| connection[:command_receipts][receipt_id: receipt_id] }
    end

    def prepare_effect(claim, ordinal:, kind:, identity: {})
      effect_id = SecureRandom.uuid
      now = timestamp
      database.transaction do |connection|
        row = connection[:command_receipts][receipt_id: claim.receipt_id]
        unless row && row.fetch(:generation) == claim.generation && row.fetch(:state) == "executing"
          raise Hive::CommandConflict, "command receipt ownership changed before effect intent"
        end
        existing = connection[:command_effects][receipt_id: claim.receipt_id, ordinal: Integer(ordinal)]
        next existing if existing
        connection[:command_effects].insert(
          effect_id: effect_id, receipt_id: claim.receipt_id, ordinal: Integer(ordinal),
          effect_kind: kind.to_s,
          identity_json: Hive::RuntimeControlPlane::Codec.dump_json(identity),
          state: "prepared", created_at: now, updated_at: now
        )
        add_logical_bytes!(
          connection, claim.namespace_id,
          Hive::RuntimeControlPlane::Codec.dump_json(identity).bytesize + 512
        )
        connection[:command_effects][effect_id: effect_id]
      end
    end

    def update_effect(claim, effect_id:, from:, to:, evidence: nil)
      now = timestamp
      changed = database.transaction do |connection|
        receipt = connection[:command_receipts][receipt_id: claim.receipt_id]
        next 0 unless receipt && receipt.fetch(:generation) == claim.generation &&
                      receipt.fetch(:state) == "executing"
        effect = connection[:command_effects][effect_id: effect_id, receipt_id: claim.receipt_id]
        encoded_evidence = if evidence
          prior = effect[:evidence_json] ?
            Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
          Hive::RuntimeControlPlane::Codec.dump_json(
            prior.merge(Hive::RuntimeControlPlane::Codec.normalize(evidence))
          )
        end
        changed = connection[:command_effects].where(
          effect_id: effect_id, receipt_id: claim.receipt_id, state: Array(from)
        ).update(
          state: to.to_s,
          evidence_json: encoded_evidence,
          updated_at: now
        )
        if changed == 1 && evidence
          old_bytes = effect[:evidence_json].to_s.bytesize
          add_logical_bytes!(
            connection, claim.namespace_id,
            encoded_evidence.bytesize - old_bytes
          )
        end
        changed
      end
      raise Hive::CommandConflict, "command effect ownership changed" unless changed == 1
      true
    end

    def record_effect_submission(receipt_id:, effect_id:, principal:, request_fingerprint:,
                                 kind:, identity:)
      correlation = {
        "kind" => kind.to_s,
        "identity" => Hive::RuntimeControlPlane::Codec.normalize(identity)
      }
      now = timestamp
      changed = database.transaction do |connection|
        receipt = connection[:command_receipts][receipt_id: receipt_id.to_s]
        next 0 unless receipt && receipt.fetch(:state) == "executing" &&
                      receipt.fetch(:principal) == principal.to_s &&
                      receipt.fetch(:request_fingerprint) == request_fingerprint.to_s
        effect = connection[:command_effects][
          effect_id: effect_id.to_s, receipt_id: receipt_id.to_s
        ]
        next 0 unless effect && %w[prepared submitted].include?(effect.fetch(:state))
        prior = effect[:evidence_json] ?
          Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
        submissions = Array(prior["submissions"])
        submissions << correlation unless submissions.include?(correlation)
        evidence = prior.merge("submissions" => submissions)
        encoded = Hive::RuntimeControlPlane::Codec.dump_json(evidence)
        count = connection[:command_effects].where(
          effect_id: effect_id.to_s, receipt_id: receipt_id.to_s,
          state: effect.fetch(:state), updated_at: effect.fetch(:updated_at)
        ).update(state: "submitted", evidence_json: encoded, updated_at: now)
        if count == 1
          add_logical_bytes!(
            connection, receipt.fetch(:namespace_id),
            encoded.bytesize - effect[:evidence_json].to_s.bytesize
          )
        end
        count
      end
      raise Hive::CommandConflict, "command effect submission changed" unless changed == 1
      true
    end

    def acquire_pin(receipt_id:, principal:, intent_id:, intent_generation:,
                    retry_horizon_expires_at:, owner_host: Socket.gethostname,
                    owner_pid: Process.pid, owner_process_start: nil)
      owner_process_start ||= process_start(owner_pid)
      horizon = parse_retry_horizon!(retry_horizon_expires_at)
      intent_generation = Integer(intent_generation)
      raise Hive::UsageError, "intent generation must be nonnegative" if intent_generation.negative?
      now_time = @clock.call.utc
      now = Hive::RuntimeControlPlane::Codec.dump_time(now_time)
      row = database.transaction do |connection|
        receipt = connection[:command_receipts][receipt_id: receipt_id]
        raise Hive::UsageError, "unknown command receipt #{receipt_id}" unless receipt
        raise Hive::CommandConflict unless receipt.fetch(:principal) == principal.to_s
        existing = connection[:command_receipt_pins][
          receipt_id: receipt_id, principal: principal.to_s,
          intent_id: intent_id.to_s, intent_generation: intent_generation
        ]
        if existing
          unless existing[:retry_horizon_expires_at] == Hive::RuntimeControlPlane::Codec.dump_time(horizon)
            raise Hive::CommandConflict, "pin retry horizon cannot be changed for an acquisition identity"
          end
          if existing.fetch(:lifecycle_status) != "active"
            raise Hive::CommandUnresolved.new(
              reason: "command_pin_horizon_elapsed",
              message: "receipt pin was already released; close the intent and begin a new " \
                       "acquisition identity with a fresh future horizon"
            )
          end
          next existing
        end
        unless horizon > now_time
          raise Hive::UsageError, "a new receipt pin requires a future retry horizon"
        end
        pin_id = SecureRandom.uuid
        connection[:command_receipt_pins].insert(
          pin_id: pin_id, receipt_id: receipt_id, principal: principal.to_s,
          intent_id: intent_id.to_s, intent_generation: intent_generation,
          generation: 1, owner_host: owner_host, owner_pid: owner_pid,
          owner_process_start: owner_process_start, lifecycle_status: "active",
          retry_horizon_expires_at: Hive::RuntimeControlPlane::Codec.dump_time(horizon),
          created_at: now, updated_at: now
        )
        add_logical_bytes!(connection, receipt.fetch(:namespace_id), 512)
        connection[:command_receipt_pins][pin_id: pin_id]
      end
      pin_from(row)
    rescue ArgumentError, TypeError
      raise Hive::UsageError, "intent generation must be nonnegative"
    end

    def close_pin(receipt_id:, principal:, intent_id:, intent_generation:)
      now = timestamp
      database.transaction do |connection|
        pin = connection[:command_receipt_pins][
          receipt_id: receipt_id, principal: principal.to_s,
          intent_id: intent_id.to_s, intent_generation: Integer(intent_generation)
        ]
        next false unless pin && pin.fetch(:lifecycle_status) == "active"
        connection[:command_receipt_pins].where(
          pin_id: pin.fetch(:pin_id), generation: pin.fetch(:generation),
          lifecycle_status: "active"
        ).update(
          lifecycle_status: "closed", generation: pin.fetch(:generation) + 1,
          released_at: now, updated_at: now
        ) == 1
      end
    rescue ArgumentError, TypeError
      false
    end

    def allocate_successor(namespace_id:, principal:, intent_id:, intent_version:,
                           predecessor_receipt_id:, delivery_cycle_id:, request_fingerprint:)
      intent_version, now = Integer(intent_version), timestamp
      database.transaction do |connection|
        existing = connection[:command_successor_allocations][
          namespace_id: namespace_id, principal: principal.to_s,
          intent_id: intent_id.to_s, intent_version: intent_version,
          delivery_cycle_id: delivery_cycle_id.to_s
        ]
        if existing
          unless existing.fetch(:request_fingerprint) == request_fingerprint.to_s
            raise Hive::CommandConflict, "successor cycle request identity changed"
          end
          next successor_payload(existing)
        end
        predecessor = connection[:command_receipts][receipt_id: predecessor_receipt_id]
        valid = predecessor && predecessor.fetch(:namespace_id) == namespace_id &&
          predecessor.fetch(:principal) == principal.to_s && predecessor.fetch(:state) == "failed" &&
          predecessor.fetch(:retry_eligible) == 1
        raise Hive::CommandUnresolved.new(message: "predecessor is not eligible for a successor") unless valid
        latest = connection[:command_successor_allocations]
          .where(namespace_id: namespace_id, principal: principal.to_s, intent_id: intent_id.to_s,
                 intent_version: intent_version)
          .order(Sequel.desc(:allocation_version)).first
        if latest && latest[:successor_receipt_id] != predecessor_receipt_id.to_s
          raise Hive::CommandConflict, "successor predecessor is stale"
        end
        ordinal = latest ? latest.fetch(:successor_ordinal) + 1 : 1
        version = latest ? latest.fetch(:allocation_version) + 1 : 1
        successor_identity = Digest::SHA256.hexdigest(
          [ namespace_id, principal, intent_id, intent_version, delivery_cycle_id, ordinal ].join("\0")
        )
        allocation_id = SecureRandom.uuid
        connection[:command_successor_allocations].insert(
          allocation_id: allocation_id, namespace_id: namespace_id, principal: principal.to_s,
          intent_id: intent_id.to_s, intent_version: intent_version,
          delivery_cycle_id: delivery_cycle_id.to_s,
          predecessor_receipt_id: predecessor_receipt_id.to_s,
          successor_key_identity: successor_identity, successor_ordinal: ordinal,
          request_fingerprint: request_fingerprint.to_s, allocation_version: version,
          created_at: now
        )
        add_logical_bytes!(connection, namespace_id, 512)
        successor_payload(connection[:command_successor_allocations][allocation_id: allocation_id])
      end
    rescue ArgumentError, TypeError
      raise Hive::UsageError, "intent version must be an integer"
    end

    private

    def reclaim_dead_executing_owners(trigger_claim, scope:)
      authority = @maintenance_authority || Hive::CommandMaintenanceAuthority.local
      candidates = database.read do |connection|
        dataset = connection[:command_receipts].where(state: "executing")
        dataset = dataset.where(namespace_id: trigger_claim.namespace_id) if scope == "namespace"
        dataset.order(:updated_at, :receipt_id)
          .limit(MAX_RECLAMATION_PROBES_PER_ADMISSION).all
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
        connection[:command_maintenance_audit].insert(
          audit_id: SecureRandom.uuid, receipt_id: row.fetch(:receipt_id),
          namespace_id: row.fetch(:namespace_id),
          acting_principal: authority.principal,
          principal_source: authority.principal_source,
          authority_basis: authority.authority_basis,
          peer_address: authority.peer_address,
          action: "automatic_admission_orphan_reclassification",
          affected_principal: row.fetch(:principal),
          reason: "capacity admission for #{trigger_claim.receipt_id}",
          evidence_json: Hive::RuntimeControlPlane::Codec.dump_json(proof),
          created_at: now
        )
        add_logical_bytes!(
          connection, row.fetch(:namespace_id),
          Hive::RuntimeControlPlane::Codec.dump_json(proof).bytesize + 512
        )
        true
      end
    end

    def parse_retry_horizon!(value)
      raise Hive::UsageError, "retry_horizon_expires_at is required" if value.nil?
      source = value.to_s
      unless source.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        raise Hive::UsageError, "retry_horizon_expires_at must include an absolute UTC offset"
      end
      Time.iso8601(source).utc
    rescue ArgumentError
      raise Hive::UsageError, "retry_horizon_expires_at must be an absolute canonical UTC timestamp"
    end

    def pin_from(row)
      Pin.new(
        pin_id: row.fetch(:pin_id), receipt_id: row.fetch(:receipt_id),
        principal: row.fetch(:principal), intent_id: row.fetch(:intent_id),
        intent_generation: row.fetch(:intent_generation), generation: row.fetch(:generation),
        retry_horizon_expires_at: row[:retry_horizon_expires_at],
        lifecycle_status: row.fetch(:lifecycle_status)
      )
    end

    def successor_payload(row)
      {
        "allocation_id" => row.fetch(:allocation_id),
        "successor_key_identity" => row.fetch(:successor_key_identity),
        "successor_ordinal" => row.fetch(:successor_ordinal),
        "allocation_version" => row.fetch(:allocation_version),
        "predecessor_receipt_id" => row.fetch(:predecessor_receipt_id),
        "delivery_cycle_id" => row.fetch(:delivery_cycle_id)
      }
    end

    def require_extension!
      return if Hive::RuntimeControlPlane::CommandSchema.installed?(database)

      raise Hive::ConfigError,
            "command receipts are not installed; run `hive setup --install-command-receipts`"
    end

    def classify_existing!(row, principal:, request_fingerprint:, project_root:)
      unless row.fetch(:principal) == principal.to_s &&
             row.fetch(:request_fingerprint) == request_fingerprint
        raise Hive::CommandConflict
      end

      public_receipt = public_receipt(row)
      case row.fetch(:state)
      when *TERMINAL_STATES
        claim_from(row, :replay, project_root: project_root)
      when "prepared", "executing"
        raise Hive::CommandInProgress.new(command_receipt: public_receipt)
      when "unresolved", "aborted"
        if resumable_prune?(row)
          return claim_from(row, :resume, project_root: project_root)
        end
        raise Hive::CommandUnresolved.new(command_receipt: public_receipt)
      else
        raise Hive::RuntimeControlPlane::IntegrityError.new(
          "command receipt has an unknown state",
          code: :command_receipt_state_invalid,
          action: Hive::RuntimeControlPlane::Database::BACKUP_ACTION
        )
      end
    end

    def claim_from(row, disposition, project_root: nil)
      result = row[:result_json] && Hive::RuntimeControlPlane::Codec.load_json(row[:result_json])
      Claim.new(
        disposition: disposition,
        receipt_id: row.fetch(:receipt_id),
        namespace_id: row.fetch(:namespace_id),
        generation: row.fetch(:generation),
        state: row.fetch(:state),
        principal: row.fetch(:principal),
        request_fingerprint: row.fetch(:request_fingerprint),
        result: result,
        status: row[:result_status],
        reason: row[:typed_reason],
        public_receipt: public_receipt(row),
        project_root: project_root
      )
    end

    def public_receipt(row)
      {
        "id" => row.fetch(:receipt_id),
        "generation" => row.fetch(:generation),
        "state" => row.fetch(:state)
      }
    end

    def transition!(claim, from:, to:, updates: {}, executing_delta: 0, execution_policy: nil)
      now = timestamp
      changed = database.transaction do |connection|
        row = connection[:command_receipts][receipt_id: claim.receipt_id]
        expected = Array(from)
        next 0 unless row && row.fetch(:generation) == claim.generation &&
                      expected.include?(row.fetch(:state))

        if execution_policy
          Hive::CommandReceiptCapacity.new(
            database: database, policy: execution_policy
          ).admit_execution!(connection, namespace_id: claim.namespace_id)
        end

        count = connection[:command_receipts]
          .where(receipt_id: claim.receipt_id, generation: claim.generation, state: expected)
          .update({ state: to, generation: claim.generation + 1, updated_at: now }.merge(updates))
        if count == 1 && !executing_delta.zero? && capacity_counted?(row)
          connection[:command_capacity].where(namespace_id: claim.namespace_id).update(
            executing_count: Sequel[:executing_count] + executing_delta,
            revision: Sequel[:revision] + 1,
            updated_at: now
          )
        end
        count
      end
      raise Hive::CommandConflict, "command receipt ownership changed" unless changed == 1

      row = receipt(claim.receipt_id)
      claim_from(row, claim.disposition, project_root: claim.project_root)
    end

    def finalize!(claim, state:, result:, status:, reason:, retry_eligible: false)
      result_json = Hive::RuntimeControlPlane::Codec.dump_json(result)
      if result_json.bytesize > MAX_RESULT_BYTES
        mark_unresolved(claim, reason: "result_too_large")
        raise Hive::CommandUnresolved.new(message: "original command result exceeded the durable receipt limit")
      end
      now = timestamp
      changed = database.transaction do |connection|
        row = connection[:command_receipts][receipt_id: claim.receipt_id]
        next 0 unless row && row.fetch(:generation) == claim.generation &&
                      %w[prepared executing unresolved].include?(row.fetch(:state))

        was_executing = row.fetch(:state) == "executing"
        count = connection[:command_receipts]
          .where(receipt_id: claim.receipt_id, generation: claim.generation, state: row.fetch(:state))
          .update(
            state: state,
            generation: claim.generation + 1,
            result_json: result_json,
            result_digest: Digest::SHA256.hexdigest(result_json),
            result_status: Integer(status),
            typed_reason: reason&.to_s,
            retry_eligible: retry_eligible ? 1 : 0,
            terminal_at: now,
            updated_at: now
          )
        if count == 1 && capacity_counted?(row)
          connection[:command_capacity].where(namespace_id: claim.namespace_id).update(
            nonterminal_count: Sequel[:nonterminal_count] - 1,
            executing_count: Sequel[:executing_count] - (was_executing ? 1 : 0),
            logical_bytes: Sequel[:logical_bytes] + result_json.bytesize,
            revision: Sequel[:revision] + 1,
            updated_at: now
          )
        end
        count
      end
      raise Hive::CommandConflict, "command receipt ownership changed" unless changed == 1

      claim_from(receipt(claim.receipt_id), :replay, project_root: claim.project_root)
    end

    def timestamp
      Hive::RuntimeControlPlane::Codec.dump_time(@clock.call.utc)
    end

    def process_start(pid)
      Hive::Lock.process_start_time(pid) ||
        raise(Hive::ConfigError, "cannot record command owner process start time")
    end

    def logical_bytes(request)
      Hive::RuntimeControlPlane::Codec.dump_json(safe_request(request)).bytesize + 1024
    end

    def capacity_counted?(row)
      !(row[:command] == "receipt" && row[:mode] == "prune")
    end

    def add_logical_bytes!(connection, namespace_id, delta)
      return if delta.zero?
      expression = if delta.positive?
        Sequel[:logical_bytes] + delta
      else
        Sequel.function(:max, Sequel[:logical_bytes] + delta, 0)
      end
      connection[:command_capacity].where(namespace_id: namespace_id).update(
        logical_bytes: expression, revision: Sequel[:revision] + 1, updated_at: timestamp
      )
    end

    def resumable_prune?(row)
      return false unless row[:command] == "receipt" && row[:mode] == "prune" && row[:state] == "unresolved"
      database.read do |connection|
        connection[:command_maintenance_batches].where(
          administrative_receipt_id: row.fetch(:receipt_id), state: %w[prepared executing]
        ).any?
      end
    end

    def safe_request(value, parent_key = nil)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key.to_s] = safe_request(child, key.to_s)
        end
      when Array
        value.map { |child| safe_request(child, parent_key) }
      when String
        if %w[observation observation_token token credential secret].include?(parent_key)
          { "sha256" => Digest::SHA256.hexdigest(value), "bytes" => value.bytesize }
        else
          value
        end
      else
        value
      end
    end

    def intake_disabled!
      raise Hive::CommandIntakeDisabled,
        "command receipt keyed intake is disabled for this namespace; enable " \
        "command_receipts.keyed_intake_enabled in the canonical project config"
    end
  end
end
