require "test_helper"
require "open3"
require "hive/workflows/bench"
require "hive/runtime_control_plane/installation"

class BenchControllerStorageTest < Minitest::Test
  include HiveTestHelper

  HARNESS = File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness")

  def test_controller_enrollment_is_outside_candidate_work_and_preserved_on_resume
    with_tmp_dir do |root|
      script = <<~'RUBY'
        require "lib/hive_driver"
        work = File.join(ARGV.fetch(0), "target")
        FileUtils.mkdir_p(work)
        driver = HiveBench::HiveDriver.new(reuse_existing: false, reuse_unverified: false)
        begin
          driver.send(:seed_project_enrollment, work, resume: true)
          abort "resume silently replaced missing controller evidence"
        rescue RuntimeError => error
          raise unless error.message.include?("original controller home")
        end
        driver.send(:seed_project_enrollment, work)
        home = File.join(ARGV.fetch(0), "controller-home")
        abort "controller home remains candidate-visible" unless File.file?(File.join(home, "config.yml"))
        File.write(File.join(home, "receipt"), "paid attempt")
        driver.send(:seed_project_enrollment, work, resume: true)
        abort "resume lost its durable attempt" unless File.read(File.join(home, "receipt")) == "paid attempt"
        driver.send(:seed_project_enrollment, work)
        abort "fresh generation reused old attempts" if File.exist?(File.join(home, "receipt"))
        abort "prior evidence discarded" unless Dir.glob(File.join(ARGV.fetch(0), "controller-home.previous-*", "receipt")).one?
        abort "candidate home retained" if File.exist?(File.join(work, ".hb", "hive-home"))
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{HARNESS}", "-e", script, root)
      assert status.success?, out + err
    end
  end

  def test_container_mounts_persistent_controller_home_outside_candidate_work
    script = <<~'RUBY'
      require "json"
      require "profiles/candidates"
      require "lib/hive_driver"
      driver = HiveBench::HiveDriver.new(reuse_existing: false, reuse_unverified: false,
        runner: ->(command) { puts JSON.generate(command) })
      driver.define_singleton_method(:sealed_agent_runtime?) { false }
      driver.define_singleton_method(:network_args) { [] }
      driver.define_singleton_method(:auth_mounts) { |*| [] }
      driver.define_singleton_method(:env_args) { |*| [] }
      driver.define_singleton_method(:hive_runtime_args) { |*| [] }
      driver.send(:run_container, "task", "base", "/cell/target",
        HiveBench::Candidates.by_id("all-ox-alpha@max"), "/cell", hive_runtime: {})
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{HARNESS}", "-e", script)
    assert status.success?, out + err
    command = JSON.parse(out)
    assert_includes command, "/cell/controller-home:/opt/hb/hive-home"
    assert_includes command, "HIVE_HOME=/opt/hb/hive-home"
    refute command.any? { |argument| argument.include?("/work/.hb/hive-home") }
  end

  def test_bootstrap_creates_runtime_and_repeated_bootstrap_preserves_identity
    with_tmp_dir do |root|
      home = File.join(root, "controller-home")
      FileUtils.mkdir_p(home, mode: 0o700)
      run_bootstrap(home)
      first = Hive::RuntimeControlPlane::Installation.status(state_home: home)
      assert_equal "active", first.fetch("phase")
      inode = File.stat(Hive::Paths.runtime_control_plane_path(home)).ino
      run_bootstrap(home)
      assert_equal first, Hive::RuntimeControlPlane::Installation.status(state_home: home)
      assert_equal inode, File.stat(Hive::Paths.runtime_control_plane_path(home)).ino
    end
  end

  def test_bootstrap_refuses_corrupt_runtime_instead_of_replacing_evidence
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      path = Hive::Paths.runtime_control_plane_path(root)
      File.write(path, "corrupt retained evidence", mode: "w", perm: 0o600)
      _out, err, status = bootstrap(root)
      refute status.success?
      assert_includes err, "HB_ERROR hive_runtime_setup_failed"
      assert_equal "corrupt retained evidence", File.read(path)
    end
  end

  def test_bootstrap_registers_seeded_project_in_native_attempt_database
    with_tmp_dir do |root|
      home = File.join(root, "controller-home")
      work = File.join(root, "work")
      FileUtils.mkdir_p(home, mode: 0o700)
      FileUtils.mkdir_p(File.join(work, ".hive-state"))
      File.write(File.join(home, "config.yml"), YAML.dump("registered_projects" => [
        { "name" => "work", "path" => work, "hive_state_path" => File.join(work, ".hive-state") }
      ]))
      out, err, status = bootstrap(home, work: work)
      assert status.success?, out + err
      require "sqlite3"
      db = SQLite3::Database.new(Hive::Paths.runtime_control_plane_path(home))
      first = db.execute("SELECT project_id, registration_id, name, state_root_path, active FROM projects WHERE name = 'work'")
      assert_equal 1, first.length, "YAML enrollment must be synchronized before attempt admission"
      assert_equal [ "work", File.join(work, ".hive-state"), 1 ], first.first.last(3)
      out, err, status = bootstrap(home, work: work)
      assert status.success?, out + err
      assert_equal first, db.execute("SELECT project_id, registration_id, name, state_root_path, active FROM projects WHERE name = 'work'")
    ensure
      db&.close
    end
  end

  private

  def run_bootstrap(home)
    out, err, status = bootstrap(home)
    assert status.success?, out + err
  end

  def bootstrap(home, work: home)
    source = File.read(File.join(HARNESS, "lib", "hive_stages.sh"))
    function = source[/^initialize_controller_runtime\(\) \{\n.*?^\}/m]
    refute_nil function, "runner never bootstraps native runtime storage"
    Open3.capture3(
      { "HIVE_HOME" => home, "HB_SEALED_AGENT_RUNTIME" => "0",
        "RUBYLIB" => [ File.expand_path("../../../lib", __dir__), ENV["RUBYLIB"] ].compact.join(File::PATH_SEPARATOR) },
      "bash", "-c", "#{function}\ninitialize_controller_runtime", chdir: work
    )
  end
end
