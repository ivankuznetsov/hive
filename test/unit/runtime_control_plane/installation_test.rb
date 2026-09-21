require "test_helper"
require "hive/runtime_control_plane/installation"
require "open3"

class RuntimeControlPlaneInstallationTest < Minitest::Test
  include HiveTestHelper

  def test_setup_creates_current_database_and_is_idempotent_without_manifests
    with_tmp_dir do |root|
      state = File.join(root, "state")
      first = Hive::RuntimeControlPlane::Installation.setup(state_home: state)
      path = Hive::Paths.runtime_control_plane_path(state)
      database = Hive::RuntimeControlPlane::Database.new(path: path)
      database.transaction { |db| db[:installations].update(next_task_id: 42) }
      database.disconnect
      inode = File.stat(path).ino
      assert_equal first, Hive::RuntimeControlPlane::Installation.setup(state_home: state)
      assert_equal inode, File.stat(path).ino
      assert_equal 42, database.installation_identity.fetch(:next_task_id)
      assert_equal "active", first.fetch("phase")
      refute_path_exists File.join(state, ".runtime-cutover")
    ensure
      database&.disconnect
    end
  end

  def test_status_does_not_create_missing_storage
    with_tmp_dir do |root|
      state = File.join(root, "missing")
      result = Hive::RuntimeControlPlane::Installation.status(state_home: state)
      assert_equal "absent", result.fetch("phase")
      assert_equal "hive setup", result.fetch("next_action")
      refute_path_exists state
    end
  end

  def test_unsupported_existing_database_is_never_upgraded_or_replaced
    with_tmp_dir do |root|
      Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      path = Hive::Paths.runtime_control_plane_path(root)
      database = Hive::RuntimeControlPlane::Database.new(path: path)
      database.transaction { |db| db[:schema_info].update(version: 0) }
      database.disconnect
      bytes = File.binread(path)
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
        Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      end
      assert_equal :older_schema, error.code
      assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.migrate! }
      assert_equal bytes, File.binread(path)
    ensure
      database&.disconnect
    end
  end

  def test_missing_installation_identity_is_rejected
    with_tmp_dir do |root|
      Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      database = Hive::RuntimeControlPlane::Database.new(path: Hive::Paths.runtime_control_plane_path(root))
      database.transaction { |db| db[:installations].delete }
      database.disconnect
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      end
      assert_equal :installation_identity_missing, error.code
    ensure
      database&.disconnect
    end
  end

  def test_setup_recovers_from_process_death_at_database_publication
    %w[before after].each do |point|
      with_tmp_dir do |root|
        code = <<~'RUBY'
          require "hive"
          require "hive/runtime_control_plane/installation"
          root, point = ARGV
          destination = Hive::Paths.runtime_control_plane_path(root)
          rename = File.method(:rename)
          File.define_singleton_method(:rename) do |source, target|
            publishing = target == destination
            Process.kill("KILL", Process.pid) if publishing && point == "before"
            result = rename.call(source, target)
            Process.kill("KILL", Process.pid) if publishing && point == "after"
            result
          end
          Hive::RuntimeControlPlane::Installation.setup(state_home: root)
        RUBY
        _output, errors, process = Open3.capture3(
          RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", code, root, point
        )
        assert process.signaled?, errors
        assert_equal Signal.list.fetch("KILL"), process.termsig
        initial = Hive::RuntimeControlPlane::Installation.status(state_home: root)
        assert_equal point == "before" ? "absent" : "active", initial.fetch("phase")
        path = Hive::Paths.runtime_control_plane_path(root)
        inode = File.stat(path).ino if File.exist?(path)
        repaired = Hive::RuntimeControlPlane::Installation.setup(state_home: root)
        assert_equal "active", repaired.fetch("phase")
        assert_equal 1, File.stat(path).nlink
        assert_equal inode, File.stat(path).ino if inode
        assert_equal initial.fetch("installation_id"), repaired.fetch("installation_id") if inode
      end
    end
  end

  def test_simultaneous_setup_publishes_one_installation
    with_tmp_dir do |root|
      threads = 3.times.map do
        Thread.new { Hive::RuntimeControlPlane::Installation.setup(state_home: root) }
      end
      results = threads.map(&:value)
      assert_equal 1, results.map { |value| value.fetch("installation_id") }.uniq.size
      assert_equal "ok", results.first.dig("database", "status")
    end
  end

  def test_setup_rejects_a_database_that_appears_before_publication
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      original_exist = File.method(:exist?)
      target_checks = 0

      with_replaced_singleton_method(File, :exist?, lambda { |candidate|
        if candidate == path
          target_checks += 1
          target_checks > 1 || original_exist.call(candidate)
        else
          original_exist.call(candidate)
        end
      }) do
        error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
          Hive::RuntimeControlPlane::Installation.setup(state_home: root)
        end
        assert_equal :database_already_present, error.code
      end
    end
  end
end
