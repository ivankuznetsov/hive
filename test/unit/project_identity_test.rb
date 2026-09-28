# frozen_string_literal: true

require "test_helper"
require "hive/command_maintenance_authority"
require "hive/project_identity"
require "hive/runtime_control_plane/command_schema_installation"
require "json_schemer"

class ProjectIdentityTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "b" * 64
  }.freeze

  def test_first_enrollment_persists_one_private_marker_and_active_namespace
    with_store do |project, database|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      repeated = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )

      assert_equal identity, repeated
      assert_equal 0o600, File.stat(identity.marker_path).mode & 0o777
      row = database.read { |db| db[:command_namespaces][namespace_id: identity.namespace_id] }
      assert_equal "active", row.fetch(:enrollment_state)
    end
  end

  def test_read_only_resolution_never_enrolls
    with_store do |project, database|
      assert_nil Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: false
      )
      assert_empty database.read { |db| db[:command_namespaces].all }
      refute File.exist?(Hive::ProjectIdentity.marker_path(project))
    end
  end

  def test_pending_enrollment_is_read_only_until_create_resumes_activation
    with_store do |project, database|
      common_dir = Hive::ProjectIdentity.git_common_dir(project)
      digest = Digest::SHA256.hexdigest(common_dir)
      installation_id = database.installation_identity.fetch(:installation_id)
      row = Hive::ProjectIdentity.send(
        :reserve_pending!, database: database, installation_id: installation_id,
        digest: digest, project_root: project
      )

      assert_nil Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: false
      )
      refute File.exist?(Hive::ProjectIdentity.marker_path(project))
      assert_equal "pending", database.read {
        |connection| connection[:command_namespaces][namespace_id: row.fetch(:namespace_id)]
          .fetch(:enrollment_state)
      }

      identity = Hive::ProjectIdentity::Identity.new(
        namespace_id: row.fetch(:namespace_id), installation_id: installation_id,
        git_common_dir_digest: digest, enrollment_generation: 0,
        marker_path: Hive::ProjectIdentity.marker_path(project)
      )
      Hive::ProjectIdentity.send(:write_marker, identity)
      resumed = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      assert_equal row.fetch(:namespace_id), resumed.namespace_id
      assert_equal 1, resumed.enrollment_generation
      assert_equal "active", database.read {
        |connection| connection[:command_namespaces][namespace_id: row.fetch(:namespace_id)]
          .fetch(:enrollment_state)
      }
    end
  end

  def test_active_database_row_without_marker_fails_closed
    with_store do |project, database|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      File.delete(identity.marker_path)

      assert_raises(Hive::ConfigError) do
        Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)
      end
      assert_raises(Hive::ConfigError) do
        Hive::ProjectIdentity.resolve(project_root: project, database: database, create: false)
      end
    end
  end

  def test_explicit_new_identity_is_previewed_and_generation_fenced
    with_store do |project, database|
      previous = "11111111-1111-4111-8111-111111111111"
      preview = Hive::ProjectIdentity.enroll_new_identity(
        project_root: project, database: database, previous_identity: previous,
        expected_generation: 0, confirm: false, authority: owner_authority
      )
      assert_equal false, preview.fetch("confirmed")
      receipt_schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-command-receipt")))
      )
      assert_empty receipt_schema.validate(preview).to_a
      assert_empty database.read { |db| db[:command_namespaces].all }

      result = Hive::ProjectIdentity.enroll_new_identity(
        project_root: project, database: database, previous_identity: previous,
        expected_generation: 0, confirm: true, authority: owner_authority
      )
      assert_equal true, result.fetch("confirmed")
      assert_empty receipt_schema.validate(result).to_a
      assert_equal 1, result.fetch("generation")
      assert_equal "active", database.read {
        |db| db[:command_namespaces][namespace_id: result.fetch("namespace_id")].fetch(:enrollment_state)
      }
      first_audit = database.read do |db|
        db[:command_maintenance_audit][namespace_id: result.fetch("namespace_id")]
      end
      assert_equal "project_new_identity_enrollment", first_audit.fetch(:action)
      assert_equal "owner", first_audit.fetch(:acting_principal)
      assert_equal "test", first_audit.fetch(:principal_source)
      assert_equal "installation_owner", first_audit.fetch(:authority_basis)
      replacement = Hive::ProjectIdentity.enroll_new_identity(
        project_root: project, database: database,
        previous_identity: result.fetch("namespace_id"),
        expected_generation: 1, confirm: true, authority: owner_authority
      )
      refute_equal result.fetch("namespace_id"), replacement.fetch("namespace_id")
      assert_equal 2, replacement.fetch("generation")
      replacement_audit = database.read do |db|
        db[:command_maintenance_audit][namespace_id: replacement.fetch("namespace_id")]
      end
      assert_equal "project_new_identity_enrollment", replacement_audit.fetch(:action)
      assert_raises(Hive::CommandConflict) do
        Hive::ProjectIdentity.enroll_new_identity(
          project_root: project, database: database, previous_identity: previous,
          expected_generation: 0, confirm: true, authority: owner_authority
        )
      end
    end
  end

  def test_explicit_enrollment_requires_installation_owner_authority
    nonowner = Hive::CommandMaintenanceAuthority.new(
      principal: "caller", principal_source: "test"
    )

    assert_raises(Hive::ConfigError) do
      Hive::ProjectIdentity.send(:authorize_enrollment!, nil)
    end
    assert_raises(Hive::ConfigError) do
      Hive::ProjectIdentity.send(:authorize_enrollment!, nonowner)
    end
    assert_equal "installation_owner",
                 Hive::ProjectIdentity.send(:authorize_enrollment!, owner_authority)
  end

  def test_relocation_crash_recovery_activates_with_persisted_audit_context
    with_store do |project, database|
      active = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      digest = active.git_common_dir_digest
      row = database.read { |db| db[:command_namespaces][namespace_id: active.namespace_id] }
      audit = Hive::ProjectIdentity.send(
        :enrollment_audit_context, authority: owner_authority,
        previous_identity: active.namespace_id,
        expected_generation: active.enrollment_generation
      )
      pending = Hive::ProjectIdentity.send(
        :replace_active_identity!, database: database, row: row,
        installation_id: active.installation_id, digest: digest, project_root: project,
        expected_generation: active.enrollment_generation,
        authority: owner_authority, audit_context: audit
      )
      identity = Hive::ProjectIdentity::Identity.new(
        namespace_id: pending.fetch(:namespace_id), installation_id: active.installation_id,
        git_common_dir_digest: digest,
        enrollment_generation: active.enrollment_generation,
        marker_path: active.marker_path
      )
      Hive::ProjectIdentity.send(:write_marker, identity)

      recovered = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      audit_row = database.read do |db|
        db[:command_maintenance_audit][namespace_id: recovered.namespace_id]
      end
      assert_equal "project_new_identity_enrollment", audit_row.fetch(:action)
      assert_equal "owner", audit_row.fetch(:acting_principal)
      evidence = Hive::RuntimeControlPlane::Codec.load_json(audit_row.fetch(:evidence_json))
      assert_equal active.namespace_id, evidence.fetch("previous_identity")
    end
  end

  def test_enrollment_retries_a_concurrent_reservation_and_fences_confirmation_state
    with_store do |project, database|
      transaction = database.method(:transaction)
      attempts = 0
      database.define_singleton_method(:transaction) do |**kwargs, &block|
        attempts += 1
        raise Sequel::UniqueConstraintViolation, "simulated race" if attempts == 1

        transaction.call(**kwargs, &block)
      end
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      assert_equal 1, identity.enrollment_generation
      assert_equal 3, attempts

      File.delete(identity.marker_path)
      error = assert_raises(Hive::CommandConflict) do
        Hive::ProjectIdentity.enroll_new_identity(
          project_root: project, database: database,
          previous_identity: "11111111-1111-4111-8111-111111111111",
          expected_generation: 1, confirm: true, authority: owner_authority
        )
      end
      assert_equal "--previous-identity does not match the active project identity", error.message
    end
  end

  def test_read_only_resolution_rejects_marker_and_database_identity_drift
    with_store do |project, database|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      database.transaction do |connection|
        connection[:command_project_enrollments].where(namespace_id: identity.namespace_id).delete
        connection[:command_capacity].where(namespace_id: identity.namespace_id).delete
        connection[:command_namespaces].where(namespace_id: identity.namespace_id).delete
      end
      assert_raises(Hive::ConfigError) do
        database.read do |connection|
          Hive::ProjectIdentity.resolve_read_only(project_root: project, connection: connection)
        end
      end
    end

    with_store do |project, database|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      marker = JSON.parse(File.read(identity.marker_path))
      marker["installation_id"] = "other-installation"
      File.write(identity.marker_path, JSON.generate(marker))
      File.chmod(0o600, identity.marker_path)
      assert_raises(Hive::ConfigError) do
        database.read do |connection|
          Hive::ProjectIdentity.resolve_read_only(project_root: project, connection: connection)
        end
      end
    end

    with_store do |project, database|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      File.delete(identity.marker_path)
      assert_raises(Hive::ConfigError) do
        database.read do |connection|
          Hive::ProjectIdentity.resolve_read_only(project_root: project, connection: connection)
        end
      end
    end

    with_store do |project, database|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      database.transaction do |connection|
        connection[:command_namespaces].where(namespace_id: identity.namespace_id)
          .update(git_common_dir_digest: "changed")
      end
      assert_raises(Hive::ConfigError) do
        database.read do |connection|
          Hive::ProjectIdentity.resolve_read_only(project_root: project, connection: connection)
        end
      end
    end
  end

  def test_enrollment_compare_and_swap_failures_are_explicit
    with_store do |project, database|
      mismatched = {
        namespace_id: "new-namespace", enrollment_state: "pending",
        enrollment_generation: 1, installation_id: database.installation_identity.fetch(:installation_id),
        git_common_dir_digest: Digest::SHA256.hexdigest(Hive::ProjectIdentity.git_common_dir(project))
      }
      with_replaced_singleton_method(
        Hive::ProjectIdentity, :reserve_pending_with_retry!, ->(**) { mismatched }
      ) do
        assert_raises(Hive::CommandConflict) do
          Hive::ProjectIdentity.enroll_new_identity(
            project_root: project, database: database,
            previous_identity: "11111111-1111-4111-8111-111111111111",
            expected_generation: 0, confirm: true, authority: owner_authority
          )
        end
      end

      common_dir = Hive::ProjectIdentity.git_common_dir(project)
      digest = Digest::SHA256.hexdigest(common_dir)
      installation_id = database.installation_identity.fetch(:installation_id)
      row = Hive::ProjectIdentity.send(
        :reserve_pending!, database: database, installation_id: installation_id,
        digest: digest, project_root: project
      )
      assert_raises(Hive::CommandConflict) do
        Hive::ProjectIdentity.send(
          :persist_pending_audit_context!, database: database,
          row: row.merge(enrollment_generation: row.fetch(:enrollment_generation) + 1),
          authority: owner_authority, audit_context: { "attempt" => 1 }
        )
      end
      database.transaction do |connection|
        connection[:command_project_enrollments].where(
          namespace_id: row.fetch(:namespace_id)
        ).update(audit_context_json: "{}")
      end
      assert_raises(Hive::CommandConflict) do
        Hive::ProjectIdentity.send(
          :persist_pending_audit_context!, database: database, row: row,
          authority: owner_authority, audit_context: { "attempt" => 2 }
        )
      end
      database.transaction do |connection|
        connection[:command_namespaces].where(namespace_id: row.fetch(:namespace_id))
          .update(enrollment_generation: 1)
      end
      assert_raises(Hive::CommandConflict) do
        Hive::ProjectIdentity.enroll_new_identity(
          project_root: project, database: database,
          previous_identity: "11111111-1111-4111-8111-111111111111",
          expected_generation: 0, confirm: true, authority: owner_authority
        )
      end
    end

    assert_raises(Hive::CommandConflict) do
      with_replaced_singleton_method(
        Hive::ProjectIdentity, :reserve_pending!,
        ->(**) { raise Sequel::UniqueConstraintViolation, "race" }
      ) do
        Hive::ProjectIdentity.send(:reserve_pending_with_retry!)
      end
    end

    with_store do |project, database|
      assert_raises(Hive::CommandConflict) do
        Hive::ProjectIdentity.send(
          :replace_active_identity!, database: database,
          row: { namespace_id: "missing" },
          installation_id: database.installation_identity.fetch(:installation_id),
          digest: "digest", project_root: project, expected_generation: 1,
          authority: owner_authority
        )
      end
    end
  end

  private

  def owner_authority
    @owner_authority ||= Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "test", installation_owner: true
    )
  end

  def with_store
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(project)
      system("git", "init", "--quiet", project, exception: true)
      state = File.join(dir, "state")
      FileUtils.mkdir_p(state, mode: 0o700)
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(state)
      ).migrate!
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )
      yield project, database
    ensure
      database&.disconnect
    end
  end
end
