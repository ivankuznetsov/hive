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
      runner = lambda do |argv|
        calls << argv
        ok = if argv.include?("show-environment")
          true
        elsif argv.include?("is-active")
          states.fetch(argv.last).fetch(:running)
        elsif argv.include?("is-enabled")
          states.fetch(argv.last).fetch(:enabled)
        else
          true
        end
        [ "", "", Status.new(ok) ]
      end
      services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, host_os: "linux", runner: runner
      )

      services.stop!(cutover_id: "cutover-1")
      services.activate!

      mutations = calls.reject do |argv|
        argv.any? { |item| item.start_with?("is-") } || argv.include?("show-environment")
      end
      assert_equal [
        %w[systemctl --user stop hive-bot],
        %w[systemctl --user start hive-bot]
      ], mutations
    end
  end

  def test_resume_reuses_the_service_journal_and_reapplies_quiescence
    with_tmp_dir do |root|
      calls = []
      runner = lambda do |argv|
        calls << argv
        running = argv.include?("is-active") && argv.last == "hive-daemon"
        ok = argv.include?("show-environment") || running || !argv.any? { |item| item.start_with?("is-") }
        [ "", "", Status.new(ok) ]
      end
      services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: root, host_os: "linux", runner: runner
      )

      2.times { services.stop!(cutover_id: "cutover-1") }

      assert_equal 1, calls.count { |argv| argv.include?("show-environment") }
      assert_equal 2, calls.count { |argv| argv == %w[systemctl --user stop hive-daemon] }
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

  def test_macos_transitions_are_idempotent_across_partial_activation
    with_tmp_dir do |root|
      loaded = { "hive-daemon" => true, "hive-bot" => true, "hive-web" => false }
      fail_bot_once = true
      runner = lambda do |argv|
        name = argv.last.to_s.delete_prefix("gui/#{Process.uid}/local.")
        ok = case argv.first(2)
        when [ "launchctl", "print" ]
          argv.last == "gui/#{Process.uid}" ? true : loaded.fetch(name, false)
        when [ "launchctl", "bootout" ]
          loaded[name] = false
          true
        when [ "launchctl", "bootstrap" ]
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
        state_home: root, host_os: "darwin", runner: runner
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
    end
  end

  def test_package_owned_launcher_has_no_runtime_mutation_abstraction
    refute Hive::RuntimeControlPlane.const_defined?(:MaintenanceLauncher, false)
  end
end
