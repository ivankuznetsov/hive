# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "securerandom"
require "hive/atomic_file"
require "hive/errors"
require "hive/command_receipt_ledger"
require "hive/runtime_control_plane/codec"

module Hive
  # Binds one Git common directory to one receipt namespace in one runtime
  # installation. Linked worktrees therefore share identity and keys.
  module ProjectIdentity
    MARKER_NAME = "hive-project-identity.json".freeze
    Identity = Data.define(
      :namespace_id, :installation_id, :git_common_dir_digest,
      :enrollment_generation, :marker_path
    )

    module_function

    def resolve(project_root:, database:, create:)
      common_dir = git_common_dir(project_root)
      digest = Digest::SHA256.hexdigest(common_dir)
      marker = marker_path_for(common_dir)
      installation_id = database.installation_identity.fetch(:installation_id)
      persisted = read_marker(marker)

      if persisted
        return verify_marker!(
          persisted, marker: marker, digest: digest,
          installation_id: installation_id, database: database, create: create
        )
      end

      row = database.read do |connection|
        connection[:command_namespaces][
          installation_id: installation_id, git_common_dir_digest: digest
        ]
      end
      if row && row.fetch(:enrollment_state) == "active"
        raise Hive::ConfigError,
              "project receipt identity marker is missing for an existing namespace; " \
              "restore the matching marker and control-plane database together"
      end
      return nil unless create

      row ||= reserve_pending_with_retry!(
        database: database, installation_id: installation_id, digest: digest,
        project_root: project_root
      )
      identity = identity_from(row, marker)
      write_marker(identity)
      activate!(database: database, identity: identity)
      identity.with(enrollment_generation: identity.enrollment_generation + 1)
    end

    def marker_path(project_root)
      marker_path_for(git_common_dir(project_root))
    end

    # Resolve identity entirely through an already-open read-only SQLite
    # snapshot. This never creates WAL sidecars, markers, or enrollment rows.
    def resolve_read_only(project_root:, connection:)
      common_dir = git_common_dir(project_root)
      digest = Digest::SHA256.hexdigest(common_dir)
      marker = marker_path_for(common_dir)
      installation_id = connection[:installations].first&.fetch(:installation_id)
      raise Hive::ConfigError, "runtime installation identity is missing" unless installation_id
      persisted = read_marker(marker)
      row = if persisted
        unless persisted.is_a?(Hash) && persisted["schema"] == "hive-project-identity" &&
               persisted["schema_version"] == 1 && persisted["installation_id"] == installation_id &&
               persisted["git_common_dir_digest"] == digest
          raise Hive::ConfigError,
                "project receipt identity does not match this location or control-plane installation"
        end
        connection[:command_namespaces][namespace_id: persisted["namespace_id"].to_s]
      else
        connection[:command_namespaces][
          installation_id: installation_id, git_common_dir_digest: digest
        ]
      end
      if persisted && !row
        raise Hive::ConfigError,
              "project receipt identity marker names a missing command namespace"
      end
      return nil unless row
      if !persisted && row.fetch(:enrollment_state) == "active"
        raise Hive::ConfigError,
              "project receipt identity marker is missing for an existing namespace; " \
              "restore the matching marker and control-plane database together"
      end
      unless row.fetch(:installation_id) == installation_id &&
             row.fetch(:git_common_dir_digest) == digest
        raise Hive::ConfigError, "project receipt identity is not bound to this control-plane database"
      end
      identity_from(row, marker)
    end

    def enroll_new_identity(project_root:, database:, previous_identity:,
                            expected_generation:, confirm:, authority: nil)
      previous_identity = previous_identity.to_s
      unless previous_identity.match?(/\A[0-9a-f]{8}-[0-9a-f-]{27,}\z/i)
        raise Hive::UsageError, "--previous-identity must be a UUID"
      end
      generation = enrollment_generation!(expected_generation)
      authorize_enrollment!(authority)

      common_dir = git_common_dir(project_root)
      digest = Digest::SHA256.hexdigest(common_dir)
      marker = marker_path_for(common_dir)
      installation_id = database.installation_identity.fetch(:installation_id)
      row = database.read do |connection|
        connection[:command_namespaces][
          installation_id: installation_id, git_common_dir_digest: digest
        ]
      end
      actual_generation = row ? row.fetch(:enrollment_generation) : 0
      unless generation == actual_generation
        raise Hive::CommandConflict,
              "project enrollment generation changed (expected #{generation}, current #{actual_generation})"
      end

      preview = {
        "schema" => "hive-command-receipt",
        "schema_version" => 1,
        "ok" => true,
        "operation" => "enroll",
        "preview" => true,
        "confirmed" => false,
        "previous_identity" => previous_identity,
        "expected_generation" => generation,
        "namespace_id" => row&.fetch(:namespace_id),
        "warning" => "old idempotency keys cannot be retried in the new identity"
      }
      return preview unless confirm

      audit_context = enrollment_audit_context(
        authority: authority, previous_identity: previous_identity,
        expected_generation: generation
      )

      if row && row.fetch(:enrollment_state) == "active"
        unless row.fetch(:namespace_id) == previous_identity
          raise Hive::CommandConflict,
                "--previous-identity does not match the active project identity"
        end
        row = replace_active_identity!(
          database: database, row: row, installation_id: installation_id,
          digest: digest, project_root: project_root, expected_generation: generation,
          authority: authority, audit_context: audit_context
        )
      else
        row ||= reserve_pending_with_retry!(
          database: database, installation_id: installation_id,
          digest: digest, project_root: project_root, authority: authority
        )
      end
      unless row.fetch(:enrollment_state) == "pending" &&
             row.fetch(:enrollment_generation) == generation
        raise Hive::CommandConflict, "project enrollment changed before confirmation"
      end
      persist_pending_audit_context!(
        database: database, row: row, authority: authority,
        audit_context: audit_context
      )
      identity = identity_from(row, marker)
      write_marker(identity)
      activate!(
        database: database, identity: identity,
        authority: authority
      )
      preview.merge(
        "preview" => false,
        "confirmed" => true,
        "namespace_id" => identity.namespace_id,
        "generation" => identity.enrollment_generation + 1
      )
    end

    def enrollment_generation!(value)
      generation = Integer(value)
      raise Hive::UsageError, "--expected-generation must be nonnegative" if generation.negative?
      generation
    rescue ArgumentError, TypeError
      raise Hive::UsageError, "--expected-generation must be a nonnegative integer"
    end
    private_class_method :enrollment_generation!

    def git_common_dir(project_root)
      out, err, status = Open3.capture3(
        "git", "-C", File.expand_path(project_root), "rev-parse",
        "--path-format=absolute", "--git-common-dir"
      )
      unless status.success? && !out.strip.empty?
        raise Hive::ConfigError,
              "cannot resolve Git common directory for command receipts: #{err.strip}"
      end
      File.realpath(File.expand_path(out.strip, project_root))
    rescue SystemCallError => error
      raise Hive::ConfigError, "cannot resolve Git common directory for command receipts: #{error.message}"
    end

    def marker_path_for(common_dir)
      File.join(common_dir, MARKER_NAME)
    end
    private_class_method :marker_path_for

    def read_marker(path)
      return unless File.exist?(path) || File.symlink?(path)
      status = File.lstat(path)
      unless status.file? && !status.symlink? && status.uid == Process.euid &&
             (status.mode & 0o077).zero?
        raise Hive::ConfigError, "project receipt identity marker has unsafe custody: #{path}"
      end
      JSON.parse(File.binread(path))
    rescue JSON::ParserError, SystemCallError => error
      raise Hive::ConfigError, "project receipt identity marker is unreadable: #{error.message}"
    end
    private_class_method :read_marker

    def verify_marker!(payload, marker:, digest:, installation_id:, database:, create: false)
      unless payload.is_a?(Hash) && payload["schema"] == "hive-project-identity" &&
             payload["schema_version"] == 1 && payload["installation_id"] == installation_id &&
             payload["git_common_dir_digest"] == digest
        raise Hive::ConfigError,
              "project receipt identity does not match this location or control-plane installation"
      end
      namespace_id = payload["namespace_id"].to_s
      row = database.read { |connection| connection[:command_namespaces][namespace_id: namespace_id] }
      unless row && row.fetch(:installation_id) == installation_id &&
             row.fetch(:git_common_dir_digest) == digest
        raise Hive::ConfigError,
              "project receipt identity is not bound to this control-plane database"
      end
      identity = identity_from(row, marker)
      return identity if row.fetch(:enrollment_state) == "active"
      return nil unless create

      activate!(database: database, identity: identity)
      identity.with(enrollment_generation: identity.enrollment_generation + 1)
    end
    private_class_method :verify_marker!

    def reserve_pending_with_retry!(**kwargs)
      attempts = 0
      begin
        attempts += 1
        reserve_pending!(**kwargs)
      rescue Sequel::UniqueConstraintViolation
        retry if attempts < 2
        raise Hive::CommandConflict, "project identity enrollment conflicted repeatedly"
      end
    end
    private_class_method :reserve_pending_with_retry!

    def replace_active_identity!(database:, row:, installation_id:, digest:, project_root:,
                                 expected_generation:, authority:, audit_context: {})
      namespace_id = SecureRandom.uuid
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        authorize_enrollment!(authority)
        current = connection[:command_namespaces][namespace_id: row.fetch(:namespace_id)]
        unless current && current.fetch(:enrollment_state) == "active" &&
               current.fetch(:enrollment_generation) == expected_generation &&
               current.fetch(:git_common_dir_digest) == digest
          raise Hive::CommandConflict, "project enrollment changed before confirmation"
        end
        retired_digest = Digest::SHA256.hexdigest(
          [ "retired-command-namespace", current.fetch(:namespace_id), digest ].join("\0")
        )
        connection[:command_namespaces].where(namespace_id: current.fetch(:namespace_id)).update(
          git_common_dir_digest: retired_digest, updated_at: now
        )
        connection[:command_project_enrollments].where(git_common_dir_digest: digest).delete
        connection[:command_namespaces].insert(
          namespace_id: namespace_id, installation_id: installation_id,
          git_common_dir_digest: digest, project_label: File.basename(File.expand_path(project_root)),
          enrollment_state: "pending", enrollment_generation: expected_generation,
          keyed_intake_enabled: 0, policy_revision: 0, created_at: now, updated_at: now
        )
        connection[:command_project_enrollments].insert(
          git_common_dir_digest: digest, namespace_id: namespace_id,
          installation_id: installation_id, generation: expected_generation, state: "pending",
          previous_identity: current.fetch(:namespace_id),
          audit_context_json: Hive::RuntimeControlPlane::Codec.dump_json(audit_context),
          created_at: now, updated_at: now
        )
        connection[:command_capacity].insert(
          namespace_id: namespace_id, nonterminal_count: 0, executing_count: 0,
          logical_bytes: 0, revision: 0, updated_at: now
        )
        connection[:command_namespaces][namespace_id: namespace_id]
      end
    end
    private_class_method :replace_active_identity!

    def reserve_pending!(database:, installation_id:, digest:, project_root:, authority: nil)
      namespace_id = SecureRandom.uuid
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        authorize_enrollment!(authority) if authority
        existing = connection[:command_namespaces][
          installation_id: installation_id, git_common_dir_digest: digest
        ]
        next existing if existing

        connection[:command_namespaces].insert(
          namespace_id: namespace_id,
          installation_id: installation_id,
          git_common_dir_digest: digest,
          project_label: File.basename(File.expand_path(project_root)),
          enrollment_state: "pending",
          enrollment_generation: 0,
          keyed_intake_enabled: 0,
          policy_revision: 0,
          created_at: now,
          updated_at: now
        )
        connection[:command_project_enrollments].insert(
          git_common_dir_digest: digest,
          namespace_id: namespace_id,
          installation_id: installation_id,
          generation: 0,
          state: "pending",
          created_at: now,
          updated_at: now
        )
        connection[:command_capacity].insert(
          namespace_id: namespace_id, nonterminal_count: 0, executing_count: 0,
          logical_bytes: 0, revision: 0, updated_at: now
        )
        connection[:command_namespaces][namespace_id: namespace_id]
      end
    end
    private_class_method :reserve_pending!

    def write_marker(identity)
      payload = {
        "schema" => "hive-project-identity",
        "schema_version" => 1,
        "namespace_id" => identity.namespace_id,
        "installation_id" => identity.installation_id,
        "git_common_dir_digest" => identity.git_common_dir_digest,
        "enrollment_generation" => identity.enrollment_generation
      }
      Hive::AtomicFile.write(
        identity.marker_path,
        Hive::RuntimeControlPlane::Codec.dump_json(payload) + "\n",
        mode: 0o600
      )
      Hive::AtomicFile.fsync_directory(File.dirname(identity.marker_path))
    end
    private_class_method :write_marker

    def activate!(database:, identity:, audit: nil, authority: nil)
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      changed = database.transaction do |connection|
        authorize_enrollment!(authority) if authority
        enrollment = if connection.respond_to?(:[])
          enrollments = connection[:command_project_enrollments]
          enrollments[namespace_id: identity.namespace_id] if enrollments.respond_to?(:[])
        end
        persisted_audit = enrollment && enrollment[:audit_context_json] &&
          Hive::RuntimeControlPlane::Codec.load_json(enrollment.fetch(:audit_context_json))
        count = connection[:command_namespaces]
          .where(namespace_id: identity.namespace_id, enrollment_state: "pending",
                 enrollment_generation: identity.enrollment_generation)
          .update(enrollment_state: "active", activated_at: now, updated_at: now,
                  enrollment_generation: identity.enrollment_generation + 1)
        connection[:command_project_enrollments]
          .where(namespace_id: identity.namespace_id, state: "pending",
                 generation: identity.enrollment_generation)
          .update(state: "active", updated_at: now,
                  generation: identity.enrollment_generation + 1)
        audit_context = persisted_audit || audit
        if count == 1 && audit_context
          encoded_evidence = Hive::RuntimeControlPlane::Codec.dump_json(
            audit_context.fetch("evidence")
          )
          Hive::CommandReceiptLedger.insert_audit!(connection,
            audit_id: SecureRandom.uuid, namespace_id: identity.namespace_id,
            acting_principal: audit_context.fetch("acting_principal"),
            principal_source: audit_context.fetch("principal_source"),
            authority_basis: audit_context.fetch("authority_basis"),
            peer_address: audit_context["peer_address"],
            action: "project_new_identity_enrollment", affected_principal: nil,
            reason: audit_context.fetch("reason"),
            evidence_json: encoded_evidence,
            created_at: now
          )
          Hive::CommandReceiptLedger.add_logical_bytes!(
            connection, identity.namespace_id, encoded_evidence.bytesize + 512, now: now
          )
        end
        count
      end
      return if changed == 1

      row = database.read do |connection|
        connection[:command_namespaces][namespace_id: identity.namespace_id]
      end
      return if row && row.fetch(:enrollment_state) == "active"

      raise Hive::ConfigError, "project receipt identity enrollment changed concurrently"
    end
    private_class_method :activate!

    def enrollment_audit_context(authority:, previous_identity:, expected_generation:)
      {
        "acting_principal" => authority.principal,
        "principal_source" => authority.principal_source,
        "authority_basis" => authority.authority_basis,
        "peer_address" => authority.peer_address,
        "reason" => "previous_identity=#{previous_identity}",
        "evidence" => {
          "previous_identity" => previous_identity,
          "expected_generation" => expected_generation,
          "new_state" => "active"
        }
      }
    end
    private_class_method :enrollment_audit_context

    def persist_pending_audit_context!(database:, row:, authority:, audit_context:)
      encoded = Hive::RuntimeControlPlane::Codec.dump_json(audit_context)
      database.transaction do |connection|
        authorize_enrollment!(authority)
        enrollment = connection[:command_project_enrollments][namespace_id: row.fetch(:namespace_id)]
        unless enrollment && enrollment.fetch(:state) == "pending" &&
               enrollment.fetch(:generation) == row.fetch(:enrollment_generation)
          raise Hive::CommandConflict, "project enrollment changed before audit binding"
        end
        prior = enrollment[:audit_context_json]
        if prior && prior != encoded
          raise Hive::CommandConflict, "project enrollment audit context changed"
        end
        connection[:command_project_enrollments].where(
          namespace_id: row.fetch(:namespace_id), state: "pending",
          generation: row.fetch(:enrollment_generation)
        ).update(audit_context_json: encoded, updated_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc))
      end
    end
    private_class_method :persist_pending_audit_context!

    def authorize_enrollment!(authority)
      unless authority&.installation_owner?
        raise Hive::ConfigError, "project receipt enrollment requires the installation owner"
      end
      authority.authority_basis
    end
    private_class_method :authorize_enrollment!

    def identity_from(row, marker)
      Identity.new(
        namespace_id: row.fetch(:namespace_id),
        installation_id: row.fetch(:installation_id),
        git_common_dir_digest: row.fetch(:git_common_dir_digest),
        enrollment_generation: row.fetch(:enrollment_generation),
        marker_path: marker
      )
    end
    private_class_method :identity_from
  end
end
