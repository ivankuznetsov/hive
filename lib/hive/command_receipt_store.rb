# frozen_string_literal: true

require "digest"
require "securerandom"
require "socket"
require "hive/command_mutations"
require "hive/command_maintenance_authority"
require "hive/command_owner_proof"
require "hive/command_receipt_capacity"
require "hive/command_receipt_ledger"
require "hive/pid_file"
require "hive/lock"
require "hive/project_identity"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/command_schema"
require "hive/command_receipt_store/effects"
require "hive/command_receipt_store/pins"
require "hive/command_receipt_store/reclamation"
require "hive/command_receipt_store/replay"

module Hive
  class CommandReceiptStore
    include Effects
    include Pins
    include Reclamation
    include Replay
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

    def verify_extension!
      require_extension!
    rescue Hive::ConfigError
      raise
    rescue Hive::Error, Sequel::Error => error
      raise Hive::ConfigError,
            "cannot verify command receipt storage: #{error.message}"
    end

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
      persist_namespace_policy!(identity.namespace_id, policy) if
        !maintenance && !policy.keyed_intake_enabled
      owner_process_start ||= process_start(owner_pid) if execute
      attempts = 0
      begin
        inserted = false
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
        namespace_updates[:keyed_intake_enabled] = policy.keyed_intake_enabled ? 1 : 0 unless maintenance
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
        successor = connection[:command_successor_allocations].where(
          namespace_id: identity.namespace_id, principal: principal.to_s,
          successor_key_identity: normalized_key, successor_receipt_id: nil
        ).first
        if successor && successor.fetch(:request_fingerprint) != request_fingerprint
          raise Hive::CommandConflict, "successor frozen request identity changed"
        end
        connection[:command_successor_allocations].where(
          allocation_id: successor.fetch(:allocation_id)
        ).update(successor_receipt_id: receipt_id) if successor
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
      row = receipt(claim.receipt_id)
      counted = capacity_counted?(row)
      policy = Hive::CommandReceiptCapacity.load(claim.project_root) if counted
      transition!(
        claim, from: %w[unresolved aborted], to: "executing",
        updates: {
          owner_host: owner_host, owner_pid: owner_pid,
          owner_process_start: owner_process_start, owner_token: SecureRandom.hex(16)
        },
        executing_delta: counted ? 1 : 0,
        execution_policy: policy,
        reset_aborted_effects: true
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

    def abort_before_effect(claim, reason:)
      now = timestamp
      changed = database.transaction do |connection|
        row = connection[:command_receipts][receipt_id: claim.receipt_id]
        next 0 unless row && row.fetch(:generation) == claim.generation &&
                      %w[prepared executing].include?(row.fetch(:state)) &&
                      !connection[:command_effects].where(receipt_id: claim.receipt_id).any?
        count = connection[:command_receipts].where(
          receipt_id: claim.receipt_id, generation: claim.generation, state: row.fetch(:state)
        ).update(
          state: "aborted", generation: claim.generation + 1,
          typed_reason: reason.to_s, owner_token: nil, updated_at: now
        )
        if count == 1 && row.fetch(:state) == "executing" && capacity_counted?(row)
          connection[:command_capacity].where(namespace_id: claim.namespace_id).update(
            executing_count: Sequel[:executing_count] - 1,
            revision: Sequel[:revision] + 1, updated_at: now
          )
        end
        count
      end
      raise Hive::CommandConflict, "command receipt ownership changed" unless changed == 1

      claim_from(receipt(claim.receipt_id), claim.disposition, project_root: claim.project_root)
    end

    def abort_pre_submission(claim, effect_id:, reason:)
      now = timestamp
      changed = database.transaction do |connection|
        row = connection[:command_receipts][receipt_id: claim.receipt_id]
        effect = connection[:command_effects][
          receipt_id: claim.receipt_id, effect_id: effect_id.to_s
        ]
        next 0 unless row && row.fetch(:generation) == claim.generation &&
                      row.fetch(:state) == "executing" && effect &&
                      effect.fetch(:state) == "prepared"
        evidence = effect[:evidence_json] ?
          Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
        next 0 unless Array(evidence["submissions"]).empty?

        encoded = Hive::RuntimeControlPlane::Codec.dump_json(
          evidence.merge(
            "whole_effect_non_application" => true,
            "retryable_contention" => true,
            "owner_released" => true
          )
        )
        if !capacity_counted?(row)
          effect_changed = connection[:command_effects].where(
            effect_id: effect_id.to_s, receipt_id: claim.receipt_id,
            state: "prepared", updated_at: effect.fetch(:updated_at)
          ).delete
          next 0 unless effect_changed == 1
          next connection[:command_receipts].where(
            receipt_id: claim.receipt_id, generation: claim.generation, state: "executing"
          ).delete
        end

        effect_changed = connection[:command_effects].where(
          effect_id: effect_id.to_s, receipt_id: claim.receipt_id,
          state: "prepared", updated_at: effect.fetch(:updated_at)
        ).update(state: "not_applied", evidence_json: encoded, updated_at: now)
        next 0 unless effect_changed == 1

        count = connection[:command_receipts].where(
          receipt_id: claim.receipt_id, generation: claim.generation, state: "executing"
        ).update(
          state: "aborted", generation: claim.generation + 1,
          typed_reason: reason.to_s, owner_token: nil, updated_at: now
        )
        if count == 1 && capacity_counted?(row)
          connection[:command_capacity].where(namespace_id: claim.namespace_id).update(
            executing_count: Sequel[:executing_count] - 1,
            revision: Sequel[:revision] + 1, updated_at: now
          )
          add_logical_bytes!(
            connection, claim.namespace_id,
            encoded.bytesize - effect[:evidence_json].to_s.bytesize
          )
        end
        count
      end
      raise Hive::CommandConflict, "command contention outcome changed" unless changed == 1

      row = receipt(claim.receipt_id)
      row && claim_from(row, :resume, project_root: claim.project_root)
    rescue Hive::RuntimeControlPlane::CodecError
      raise Hive::CommandConflict, "command contention evidence changed"
    end

    def receipt(receipt_id)
      database.read { |connection| connection[:command_receipts][receipt_id: receipt_id] }
    end


    def allocate_successor(namespace_id:, principal:, intent_id:, intent_version:,
                           predecessor_receipt_id:, delivery_cycle_id:, request_fingerprint:,
                           project_root: nil)
      intent_version, now = Integer(intent_version), timestamp
      existing = database.read do |connection|
        connection[:command_successor_allocations][
          namespace_id: namespace_id, principal: principal.to_s,
          intent_id: intent_id.to_s, intent_version: intent_version,
          delivery_cycle_id: delivery_cycle_id.to_s
        ]
      end
      policy = existing ? nil : admission_policy!(project_root, namespace_id: namespace_id)
      persist_namespace_policy!(namespace_id, policy) if policy && !policy.keyed_intake_enabled
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
        raise Hive::CommandConflict, "successor allocation admission changed" unless policy
        intake_disabled! unless policy.keyed_intake_enabled
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
        capacity = Hive::CommandReceiptCapacity.new(database: database, policy: policy)
        capacity.admit_bytes!(
          connection, namespace_id: namespace_id, request_bytes: 512,
          occupied_installation_bytes: capacity.occupied_installation_bytes(connection: connection)
        )
        sync_namespace_policy!(connection, namespace_id, policy, now)
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

    def admission_policy!(project_root, namespace_id: nil, receipt_id: nil)
      expected_namespace = namespace_id || database.read { |connection|
        connection[:command_receipts][receipt_id: receipt_id]&.fetch(:namespace_id, nil)
      }
      raise Hive::ConfigError, "fresh keyed admission has no canonical project root" if project_root.to_s.empty?
      policy = Hive::CommandReceiptCapacity.load(project_root)
      identity = Hive::ProjectIdentity.resolve(
        project_root: project_root, database: database, create: false
      )
      unless identity && identity.namespace_id == expected_namespace
        raise Hive::CommandConflict, "keyed admission namespace changed"
      end
      policy
    end

    def sync_namespace_policy!(connection, namespace_id, policy, now)
      connection[:command_namespaces].where(namespace_id: namespace_id).update(
        keyed_intake_enabled: policy.keyed_intake_enabled ? 1 : 0,
        policy_revision: policy.revision[0, 15].to_i(16),
        nonterminal_limit: policy.nonterminal_limit,
        concurrency_limit: policy.concurrency_limit,
        byte_admission_limit: policy.byte_admission_limit,
        updated_at: now
      )
    end

    def persist_namespace_policy!(namespace_id, policy)
      raise Hive::CommandConflict, "keyed admission namespace changed" unless namespace_id

      database.transaction do |connection|
        changed = sync_namespace_policy!(connection, namespace_id, policy, timestamp)
        raise Hive::CommandConflict, "keyed admission namespace changed" unless changed == 1
      end
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


    def transition!(claim, from:, to:, updates: {}, executing_delta: 0, execution_policy: nil,
                    reset_aborted_effects: false)
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
        if count == 1 && reset_aborted_effects && row.fetch(:state) == "aborted"
          effects = connection[:command_effects].where(receipt_id: claim.receipt_id).all
          unless effects.all? { |effect| safely_not_applied_effect?(effect) }
            raise Hive::CommandConflict, "aborted command no longer has non-application proof"
          end
          connection[:command_effects].where(
            receipt_id: claim.receipt_id, state: "not_applied"
          ).update(state: "prepared", updated_at: now)
        end
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

    def capacity_counted?(row) = Hive::CommandReceiptLedger.capacity_counted?(row)

    def add_logical_bytes!(connection, namespace_id, delta)
      Hive::CommandReceiptLedger.add_logical_bytes!(
        connection, namespace_id, delta, now: timestamp
      )
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
