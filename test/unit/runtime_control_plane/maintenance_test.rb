require "test_helper"
require "hive/runtime_control_plane/maintenance"

class RuntimeControlPlaneMaintenanceTest < Minitest::Test
  include HiveTestHelper
  Status = Struct.new(:ok) { def success? = ok }

  def test_linux_services_restart_only_units_that_were_running
    with_tmp_dir do |root|
      calls = []
      states = {
        "hive-daemon" => { running: false, enabled: true },
        "hive-bot" => { running: true, enabled: false },
        "hive-web" => { running: false, enabled: false }
      }
      write_service_files(root, states.keys, platform: :linux)
      runner = lambda do |argv|
        calls << argv
        ok = if argv.include?("show-environment")
          true
        elsif argv.include?("is-active")
          states.fetch(argv.last).fetch(:running)
        elsif argv.include?("is-enabled")
          states.fetch(argv.last).fetch(:enabled)
        elsif argv[0, 3] == %w[systemctl --user stop]
          states.fetch(argv.last)[:running] = false
          true
        elsif argv[0, 3] == %w[systemctl --user start]
          states.fetch(argv.last)[:running] = true
          true
        else
          true
        end
        [ "", "", Status.new(ok) ]
      end
      services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, home: root, host_os: "linux", runner: runner
      )

      services.stop!(cutover_id: "cutover-1")
      services.activate!

      mutations = calls.reject do |argv|
        argv.any? { |item| item.start_with?("is-") } || argv.include?("show-environment")
      end
      assert_equal [
        %w[systemctl --user stop hive-bot],
        %w[systemctl --user daemon-reload],
        %w[systemctl --user start hive-bot]
      ], mutations
    end
  end

  def test_resume_reuses_the_service_journal_and_reapplies_quiescence
    with_tmp_dir do |root|
      calls = []
      running = true
      write_service_files(root, [ "hive-daemon" ], platform: :linux)
      runner = lambda do |argv|
        calls << argv
        ok = if argv.include?("show-environment")
          true
        elsif argv.include?("is-active")
          argv.last == "hive-daemon" && running
        elsif argv.include?("is-enabled")
          argv.last == "hive-daemon"
        elsif argv[0, 3] == %w[systemctl --user stop]
          running = false
          true
        else
          true
        end
        [ "", "", Status.new(ok) ]
      end
      services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, home: root, host_os: "linux", runner: runner
      )

      2.times { services.stop!(cutover_id: "cutover-1") }

      assert_equal 1, calls.count { |argv| argv.include?("show-environment") }
      assert_equal 1, calls.count { |argv| argv == %w[systemctl --user stop hive-daemon] }
    end
  end

  def test_corrupt_or_cross_cutover_journal_fails_closed
    with_tmp_dir do |root|
      current = File.join(root, ".runtime-cutover", "current")
      FileUtils.mkdir_p(current)
      path = File.join(current, "services.json")
      File.binwrite(path, "{\n")
      services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, host_os: "linux", runner: ->(*) { raise "unexpected" }
      )
      error = assert_raises(Hive::RuntimeControlPlane::Error) { services.activate! }
      assert_equal :service_lifecycle_failed, error.code

      File.binwrite(path, JSON.generate(
        "cutover_id" => "other", "running" => []
      ))
      error = assert_raises(Hive::RuntimeControlPlane::Error) do
        services.stop!(cutover_id: "cutover-1")
      end
      assert_equal :service_lifecycle_failed, error.code
    end
  end

  def test_cutover_stop_respects_the_user_service_target_lock
    with_tmp_dir do |root|
      write_service_files(root, [ "hive-daemon" ], platform: :linux)
      calls = []
      runner = lambda do |argv|
        calls << argv
        ok = argv.include?("show-environment") ||
          (argv.include?("is-active") && argv.last == "hive-daemon") ||
          (argv.include?("is-enabled") && argv.last == "hive-daemon")
        [ "", "", Status.new(ok) ]
      end
      target = File.join(root, ".config/systemd/user/hive-daemon.service")
      definition = Hive::UserService::Definition.new(
        platform: :linux,
        service_name: "hive-daemon",
        target_path: target,
        content: "managed service\n"
      )
      transaction = Hive::UserService::Transaction.new(
        definition: definition,
        home: root,
        lock_wait: 0.05
      )
      ready = Queue.new
      release = Queue.new
      holder = Thread.new do
        transaction.with_lock do
          ready << true
          release.pop
        end
      end
      ready.pop
      services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root,
        home: root,
        host_os: "linux",
        runner: runner
      )

      error = assert_raises(Hive::RuntimeControlPlane::Error) do
        services.stop!(cutover_id: "cutover-locked")
      end

      assert_equal :service_lifecycle_failed, error.code
      refute calls.any? { |argv| argv[0, 3] == %w[systemctl --user stop] }
      journal = JSON.parse(File.read(
        File.join(root, ".runtime-cutover", "current", "services.json")
      ))
      assert_equal [ "hive-daemon" ], journal.fetch("running")
      refute journal.fetch("activated")
    ensure
      release << true if holder&.alive?
      holder&.join
    end
  end

  def test_macos_transitions_are_idempotent_across_partial_activation
    with_tmp_dir do |root|
      calls = []
      loaded = { "hive-daemon" => true, "hive-bot" => true, "hive-web" => false }
      write_service_files(root, %w[hive-daemon hive-bot], platform: :macos)
      fail_bot_once = true
      runner = lambda do |argv|
        calls << argv
        name = argv.last.to_s.delete_prefix("gui/#{Process.uid}/local.")
        ok = case argv.first(2)
        when [ "launchctl", "print" ]
          argv.last == "gui/#{Process.uid}" ? true : loaded.fetch(name, false)
        when [ "launchctl", "list" ]
          loaded.fetch(argv.last.delete_prefix("local."), false)
        when [ "launchctl", "unload" ]
          service = File.basename(argv.last, ".plist").delete_prefix("local.")
          loaded[service] = false
          true
        when [ "launchctl", "load" ]
          service = File.basename(argv.last, ".plist").delete_prefix("local.")
          if service == "hive-bot" && fail_bot_once
            fail_bot_once = false
            false
          else
            loaded[service] = true
            true
          end
        else
          false
        end
        [ "", ok ? "" : "failed", Status.new(ok) ]
      end
      services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, home: root, host_os: "darwin", runner: runner
      )

      services.stop!(cutover_id: "cutover-1")
      services.stop!(cutover_id: "cutover-1")
      assert_raises(Hive::RuntimeControlPlane::Error) { services.activate! }
      services.activate!
      services.activate!

      assert services.activated?
      assert loaded.fetch("hive-daemon")
      assert loaded.fetch("hive-bot")
      refute loaded.fetch("hive-web"), "only services running before cutover are restarted"
      assert calls.any? { |argv| argv.first(2) == %w[launchctl unload] }
      assert calls.any? { |argv| argv.first(2) == %w[launchctl load] }
      refute calls.any? { |argv| %w[bootout bootstrap].include?(argv[1]) }
    end
  end

  def test_package_owned_launcher_has_no_runtime_mutation_abstraction
    refute Hive::RuntimeControlPlane.const_defined?(:MaintenanceLauncher, false)
  end

  def test_unsupported_missing_and_unsafe_service_managers_fail_closed
    with_tmp_dir do |root|
      unsupported = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, host_os: "windows", runner: ->(*) { raise "unexpected" }
      )
      assert_equal :service_manager_unavailable,
                   assert_raises(Hive::RuntimeControlPlane::Error) {
                     unsupported.stop!(cutover_id: "cutover")
                   }.code

      missing = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, host_os: "linux",
        runner: ->(*) { raise Errno::ENOENT, "systemctl" }
      )
      assert_equal :service_manager_unavailable,
                   assert_raises(Hive::RuntimeControlPlane::Error) {
                     missing.stop!(cutover_id: "cutover")
                   }.code

      current = File.join(root, ".runtime-cutover", "current")
      FileUtils.mkdir_p(current)
      FileUtils.mkdir_p(File.join(current, "services.json"))
      unsafe = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, host_os: "linux", runner: ->(*) { raise "unexpected" }
      )
      assert_equal :service_lifecycle_failed,
                   assert_raises(Hive::RuntimeControlPlane::Error) { unsafe.activate! }.code
    end
  end

  private

  def write_service_files(home, names, platform:)
    names.each do |name|
      path = if platform == :linux
        File.join(home, ".config/systemd/user", "#{name}.service")
      else
        File.join(home, "Library/LaunchAgents", "local.#{name}.plist")
      end
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "managed service\n")
    end
  end
end
