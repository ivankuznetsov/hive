# frozen_string_literal: true

require "test_helper"
require "hive/project_identity"
require "hive/runtime_control_plane/command_schema_installation"

class ProjectIdentityTest < Minitest::Test
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
    end
  end

  def test_explicit_new_identity_is_previewed_and_generation_fenced
    with_store do |project, database|
      previous = "11111111-1111-4111-8111-111111111111"
      preview = Hive::ProjectIdentity.enroll_new_identity(
        project_root: project, database: database, previous_identity: previous,
        expected_generation: 0, confirm: false
      )
      assert_equal false, preview.fetch("confirmed")
      assert_empty database.read { |db| db[:command_namespaces].all }

      result = Hive::ProjectIdentity.enroll_new_identity(
        project_root: project, database: database, previous_identity: previous,
        expected_generation: 0, confirm: true
      )
      assert_equal true, result.fetch("confirmed")
      assert_equal 1, result.fetch("generation")
      assert_equal "active", database.read {
        |db| db[:command_namespaces][namespace_id: result.fetch("namespace_id")].fetch(:enrollment_state)
      }
      replacement = Hive::ProjectIdentity.enroll_new_identity(
        project_root: project, database: database,
        previous_identity: result.fetch("namespace_id"),
        expected_generation: 1, confirm: true
      )
      refute_equal result.fetch("namespace_id"), replacement.fetch("namespace_id")
      assert_equal 2, replacement.fetch("generation")
      assert_raises(Hive::CommandConflict) do
        Hive::ProjectIdentity.enroll_new_identity(
          project_root: project, database: database, previous_identity: previous,
          expected_generation: 0, confirm: true
        )
      end
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
          expected_generation: 1, confirm: true
        )
      end
      assert_equal "--previous-identity does not match the active project identity", error.message
    end
  end

  private

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
