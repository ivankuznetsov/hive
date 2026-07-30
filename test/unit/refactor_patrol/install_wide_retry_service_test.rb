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
      clean_env = trusted_executable(root, "env")
      systemctl = trusted_executable(root, "systemctl")
      service = Service.new(
        host_os: "linux",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        systemd_unit_directory: root,
        clean_env: clean_env,
        systemctl: systemctl,
        runner: lambda do |argv|
          calls << argv
          argv.fetch(1) != "bootout"
        end
      )
      authorized = runtime(root)

      result = service.ensure!(runtime: authorized)

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
      assert_includes service_bytes, authorized.candidate.path
      assert_includes service_bytes, authorized.interpreter.path
      assert_includes service_bytes, "TimeoutStartSec=615"
      assert_includes service_bytes, "--all-users --resume"
      assert_includes timer_bytes, "OnUnitActiveSec=1h"
      assert_equal(
        [
          [ systemctl, "daemon-reload" ],
          [
            systemctl, "enable", "--now",
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
      authorized = runtime(root)
      first = service.ensure!(runtime: authorized)
      before = Dir.children(root).to_h do |name|
        [ name, File.binread(File.join(root, name)) ]
      end

      second = service.ensure!(runtime: authorized)

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
        service.ensure!(runtime: authorized)
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
      clean_env = trusted_executable(root, "env")
      launchctl = trusted_executable(root, "launchctl")
      service = Service.new(
        host_os: "darwin",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        launchd_unit_directory: root,
        clean_env: clean_env,
        launchctl: launchctl,
        runner: lambda do |argv|
          calls << argv
          argv.fetch(1) != "bootout"
        end
      )
      authorized = runtime(root)

      result = service.ensure!(runtime: authorized)

      assert_equal "macos", result.platform
      plist = File.binread(
        File.join(root, "#{Service::LAUNCHD_LABEL}.plist")
      )
      assert_includes plist, authorized.candidate.path
      assert_includes plist, authorized.interpreter.path
      assert_includes plist, clean_env
      assert_includes plist, "<integer>3600</integer>"
      refute_includes plist, "<key>TimeOut</key>"
      assert_equal [
        [ launchctl, "bootout", "system/#{Service::LAUNCHD_LABEL}" ],
        [
          launchctl, "bootstrap", "system",
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
    error = with_tmp_dir do |root|
      assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: runtime(root))
      end
    end
    assert_match(/requires root authority/, error.message)

    with_tmp_dir do |root|
      authorized = runtime(root)
      unsafe_candidate =
        authorized.candidate.with(path: "/tmp/hive binary")
      unsafe = authorized.with(candidate: unsafe_candidate)
      service = Service.new(
        host_os: "linux",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid
      )
      error = assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: unsafe)
      end
      assert_match(/changed after activation|unit-safe/, error.message)
    end
  end

  def test_rejects_a_non_authorized_runtime_before_filesystem_access
    service = Service.new(
      host_os: "linux",
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid,
      lstat: ->(_path) { flunk("malformed runtime must fail first") }
    )

    error = assert_raises(Hive::ConfigError) do
      service.ensure!(runtime: Object.new)
    end

    assert_match(/requires an authorized runtime/, error.message)
  end

  def test_rejects_an_unsupported_platform_without_running_a_manager
    with_tmp_dir do |root|
      service = Service.new(
        host_os: "freebsd",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        clean_env: trusted_executable(root, "env"),
        runner: ->(*) { flunk("unsupported platforms have no manager") }
      )

      error = assert_raises(Hive::UnavailableError) do
        service.ensure!(runtime: runtime(root))
      end

      assert_match(/unsupported on this platform/, error.message)
    end
  end

  def test_default_identity_and_runner_surface_manager_failure
    with_tmp_dir do |root|
      clean_env = trusted_executable(root, "env")
      systemctl = trusted_executable(root, "systemctl")
      File.binwrite(systemctl, "#!/bin/sh\nexit 1\n")
      FileUtils.chmod(0o755, systemctl)
      service = Service.new(
        host_os: "linux",
        trusted_uid: Process.euid,
        systemd_unit_directory: root,
        clean_env: clean_env,
        systemctl: systemctl
      )

      error = assert_raises(Hive::UnavailableError) do
        service.ensure!(runtime: runtime(root))
      end

      assert_match(/daemon-reload/, error.message)
      assert_path_exists File.join(root, Service::SYSTEMD_SERVICE)
      assert_path_exists File.join(root, Service::SYSTEMD_TIMER)
    end
  end

  def test_existing_unit_inspection_rejects_oversize_and_unsafe_files
    with_tmp_dir do |root|
      File.binwrite(
        File.join(root, Service::SYSTEMD_SERVICE),
        "x" * (Service::MAX_UNIT_BYTES + 1)
      )
      service = service_for(root)
      error = assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: runtime(root))
      end
      assert_match(/exceeds its size limit/, error.message)
    end

    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, Service::SYSTEMD_SERVICE))
      service = service_for(root)
      error = assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: runtime(root))
      end
      assert_match(/not a trusted regular file/, error.message)
    end
  end

  def test_post_write_verification_rejects_changed_bytes
    with_tmp_dir do |root|
      service = Service.new(
        host_os: "linux",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        systemd_unit_directory: root,
        clean_env: trusted_executable(root, "env"),
        systemctl: trusted_executable(root, "systemctl"),
        runner: ->(*) { flunk("manager must not run") },
        writer: lambda do |path, bytes|
          File.binwrite(path, "#{bytes}# tampered\n")
          FileUtils.chmod(0o644, path)
        end
      )

      error = assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: runtime(root))
      end

      assert_match(/changed while it was installed/, error.message)
    end
  end

  def test_unit_directory_and_executable_io_failures_are_wrapped
    with_tmp_dir do |root|
      units = File.join(root, "units")
      binaries = File.join(root, "bin")
      FileUtils.mkdir_p([ units, binaries ])
      FileUtils.chmod(0o777, units)
      service = Service.new(
        host_os: "linux",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        systemd_unit_directory: units,
        clean_env: trusted_executable(binaries, "env"),
        systemctl: trusted_executable(binaries, "systemctl"),
        runner: ->(*) { flunk("manager must not run") }
      )
      error = assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: runtime(root))
      end
      assert_match(/unit directory is not trusted/, error.message)
    end

    with_tmp_dir do |root|
      units = File.join(root, "units")
      FileUtils.mkdir_p(units)
      original_lstat = File.method(:lstat)
      service = Service.new(
        host_os: "linux",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        systemd_unit_directory: units,
        clean_env: trusted_executable(root, "env"),
        systemctl: trusted_executable(root, "systemctl"),
        runner: ->(*) { flunk("manager must not run") },
        lstat: lambda do |path|
          raise Errno::EIO, "units unavailable" if path == units

          original_lstat.call(path)
        end
      )
      error = assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: runtime(root))
      end
      assert_match(/cannot validate install-wide retry unit directory/,
                   error.message)
    end

    with_tmp_dir do |root|
      missing = File.join(root, "missing-env")
      service = Service.new(
        host_os: "linux",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        systemd_unit_directory: root,
        clean_env: missing,
        systemctl: trusted_executable(root, "systemctl"),
        runner: ->(*) { flunk("manager must not run") }
      )
      error = assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: runtime(root))
      end
      assert_match(/cannot validate install-wide retry clean-environment launcher/,
                   error.message)
    end
  end

  def test_refuses_an_untrusted_clean_environment_launcher
    with_tmp_dir do |root|
      clean_env = trusted_executable(root, "env")
      FileUtils.chmod(0o777, clean_env)
      service = Service.new(
        host_os: "linux",
        effective_uid: -> { Process.uid },
        trusted_uid: Process.uid,
        systemd_unit_directory: root,
        clean_env: clean_env,
        systemctl: trusted_executable(root, "systemctl"),
        runner: ->(*) { flunk("manager must not run") }
      )

      error = assert_raises(Hive::ConfigError) do
        service.ensure!(runtime: runtime(root))
      end

      assert_match(/clean-environment launcher is not trusted/, error.message)
    end
  end

  private

  def candidate
    @candidate ||= Migration::CandidateIdentity.capture(
      File.expand_path("../../../bin/hive", __dir__)
    )
  end

  def runtime(root)
    ruby = File.join(root, "ruby")
    script = File.join(root, "hive-script")
    manifest = File.join(root, "root-runtime.json")
    [
      [ ruby, "#!/bin/sh\nexit 0\n", 0o755 ],
      [ script, "# hive script\n", 0o644 ],
      [ manifest, "{}\n", 0o644 ]
    ].each do |path, bytes, mode|
      File.write(path, bytes)
      FileUtils.chmod(mode, path)
    end
    klass = Hive::RefactorPatrol::AllUsersAuthority
    klass::RuntimeIdentity.new(
      candidate: candidate,
      interpreter: runtime_file(ruby),
      script: runtime_file(script),
      manifest: runtime_file(manifest),
      gem_home: root
    )
  end

  def runtime_file(path)
    stat = File.lstat(path)
    Hive::RefactorPatrol::AllUsersAuthority::RuntimeFile.new(
      path: path,
      dev: stat.dev,
      ino: stat.ino,
      size: stat.size,
      mode: stat.mode & 0o777,
      uid: stat.uid,
      gid: stat.gid,
      mtime: stat.mtime.to_f,
      ctime: stat.ctime.to_f,
      sha256: Digest::SHA256.file(path).hexdigest
    )
  end

  def service_for(root)
    Service.new(
      host_os: "linux",
      effective_uid: -> { Process.uid },
      trusted_uid: Process.uid,
      systemd_unit_directory: root,
      clean_env: trusted_executable(root, "env"),
      systemctl: trusted_executable(root, "systemctl"),
      runner: ->(_argv) { true }
    )
  end

  def trusted_executable(root, name)
    path = File.join(root, name)
    return path if File.file?(path)

    File.write(path, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, path)
    path
  end
end
