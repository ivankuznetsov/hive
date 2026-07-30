require "test_helper"
require "hive/refactor_patrol/install_wide_retry_service"

class InstallWideRetryServiceTest < Minitest::Test
  include HiveTestHelper

  Service = Hive::RefactorPatrol::InstallWideRetryService
  Migration =
    Hive::RefactorPatrol::InstalledUsersJobSchemaMigration

  def test_linux_installs_both_managed_units_before_enabling_the_timer
    with_tmp_dir do |root|
      calls = []
      service = Service.new(
        host_os: "linux",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        systemd_unit_directory: root,
        runner: ->(argv) { calls << argv; true }
      )

      result = service.ensure!(candidate: candidate)

      assert_equal "linux", result.platform
      assert result.changed
      assert result.active
      service_bytes = File.binread(
        File.join(root, Service::SYSTEMD_SERVICE)
      )
      timer_bytes = File.binread(
        File.join(root, Service::SYSTEMD_TIMER)
      )
      assert_includes service_bytes, Service::MANAGED_MARKER
      assert_includes service_bytes, candidate.path
      assert_includes service_bytes, "--all-users --resume"
      assert_includes timer_bytes, "OnUnitActiveSec=1h"
      assert_equal(
        [
          [ "/usr/bin/systemctl", "daemon-reload" ],
          [
            "/usr/bin/systemctl", "enable", "--now",
            Service::SYSTEMD_TIMER
          ]
        ],
        calls
      )
    end
  end

  def test_exact_units_are_idempotent_and_unmanaged_conflicts_fail_before_writes
    with_tmp_dir do |root|
      service = service_for(root)
      first = service.ensure!(candidate: candidate)
      before = Dir.children(root).to_h do |name|
        [ name, File.binread(File.join(root, name)) ]
      end

      second = service.ensure!(candidate: candidate)

      assert first.changed
      refute second.changed
      assert_equal before, Dir.children(root).to_h { |name|
        [ name, File.binread(File.join(root, name)) ]
      }

      service_path = File.join(root, Service::SYSTEMD_SERVICE)
      File.write(service_path, "[Unit]\nDescription=operator unit\n")
      timer_before = File.binread(
        File.join(root, Service::SYSTEMD_TIMER)
      )
      error = assert_raises(Hive::ConfigError) do
        service.ensure!(candidate: candidate)
      end
      assert_match(/unmanaged/, error.message)
      assert_equal timer_before, File.binread(
        File.join(root, Service::SYSTEMD_TIMER)
      )
    end
  end

  def test_macos_installs_a_system_launchdaemon_with_hourly_resume
    with_tmp_dir do |root|
      calls = []
      service = Service.new(
        host_os: "darwin",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        launchd_unit_directory: root,
        runner: ->(argv) { calls << argv; true }
      )

      result = service.ensure!(candidate: candidate)

      assert_equal "macos", result.platform
      plist = File.binread(
        File.join(root, "#{Service::LAUNCHD_LABEL}.plist")
      )
      assert_includes plist, candidate.path
      assert_includes plist, "<integer>3600</integer>"
      assert_equal [
        [ "/bin/launchctl", "bootout", "system/#{Service::LAUNCHD_LABEL}" ],
        [
          "/bin/launchctl", "bootstrap", "system",
          File.join(root, "#{Service::LAUNCHD_LABEL}.plist")
        ]
      ], calls
    end
  end

  def test_refuses_non_root_authority_and_unsafe_candidate_path
    service = Service.new(
      host_os: "linux",
      effective_uid: -> { Process.uid + 1 },
      trusted_uid: Process.uid
    )
    error = assert_raises(Hive::ConfigError) do
      service.ensure!(candidate: candidate)
    end
    assert_match(/requires root authority/, error.message)

    unsafe = candidate.with(path: "/tmp/hive binary")
    service = Service.new(
      host_os: "linux",
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid
    )
    error = assert_raises(Hive::ConfigError) do
      service.ensure!(candidate: unsafe)
    end
    assert_match(/changed after activation|unit-safe/, error.message)
  end

  private

  def candidate
    @candidate ||= Migration::CandidateIdentity.capture(
      File.expand_path("../../../bin/hive", __dir__)
    )
  end

  def service_for(root)
    Service.new(
      host_os: "linux",
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid,
      systemd_unit_directory: root,
      runner: ->(_argv) { true }
    )
  end
end
