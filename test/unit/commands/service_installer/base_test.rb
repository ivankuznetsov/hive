require "test_helper"
require "hive/commands/service_installer/base"

# Direct tests for the Hive adapter policy in
# Hive::Commands::ServiceInstaller::Base. Platform-neutral file and manager
# mechanics are covered by UserServiceTest.
class ServiceInstallerBaseTest < Minitest::Test
  include HiveTestHelper

  # Tiny concrete subclass: supplies just enough to drive the base's generic
  # paths, with a fixed rendered body and a target under the test home.
  class TestInstaller < Hive::Commands::ServiceInstaller::Base
    UNIT_BODY = "test-unit-body\n".freeze

    def service_name = "hive-test"
    def cli_label = "test"
    def service_noun = "test service"
    def unit_noun = "test unit"

    def target_path
      case platform
      when :macos then File.join(@home, "Library/LaunchAgents/local.hive-test.plist")
      when :linux then File.join(@home, ".config/systemd/user/hive-test.service")
      end
    end

    def render_systemd = UNIT_BODY
    def render_launchd = UNIT_BODY

    # Expose adapter helpers for direct unit testing.
    public :ruby_shim_dir, :build_path_line, :service_manager_available?
  end

  def build(dir, **opts)
    TestInstaller.new(host_os: "linux", home: dir, binary_path: "/tmp/hive",
                      systemctl_available: false, **opts)
  end

  # ── ruby_shim_dir ──────────────────────────────────────────────────

  def installer_with_ruby_at(dir, ruby_relative)
    ruby_path = File.join(dir, ruby_relative)
    FileUtils.mkdir_p(File.dirname(ruby_path))
    File.write(ruby_path, "#!/bin/sh\n")
    FileUtils.chmod(0o755, ruby_path)
    installer = build(dir)
    installer.define_singleton_method(:which) do |name|
      name == "ruby" ? ruby_path : nil
    end
    installer
  end

  def test_ruby_shim_dir_matches_mise
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, ".local/share/mise/installs/ruby/3.4.7/bin/ruby")
      assert_equal "%h/.local/share/mise/shims", installer.ruby_shim_dir
    end
  end

  def test_ruby_shim_dir_matches_rbenv
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, ".rbenv/versions/3.4.7/bin/ruby")
      assert_equal "%h/.rbenv/shims", installer.ruby_shim_dir
    end
  end

  def test_ruby_shim_dir_matches_asdf
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, ".asdf/installs/ruby/3.4.7/bin/ruby")
      assert_equal "%h/.asdf/shims", installer.ruby_shim_dir
    end
  end

  def test_ruby_shim_dir_nil_for_system_ruby
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, "usr/bin/ruby")
      assert_nil installer.ruby_shim_dir,
                 "a system-Ruby install matches no manager and must fall through to the minimal PATH"
    end
  end

  def test_build_path_line_minimal_when_no_manager
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, "usr/bin/ruby")
      assert_equal "Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin",
                   installer.build_path_line
    end
  end

  def test_build_path_line_injects_shim_when_manager_detected
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, ".rbenv/versions/3.4.7/bin/ruby")
      assert_equal "Environment=PATH=%h/.local/bin:%h/.rbenv/shims:/usr/local/bin:/usr/bin:/bin",
                   installer.build_path_line
    end
  end

  def test_ruby_shim_dir_nil_when_ruby_not_on_path
    with_tmp_dir do |dir|
      installer = build(dir)
      installer.define_singleton_method(:which) { |_| nil }
      assert_nil installer.ruby_shim_dir
    end
  end

  # ── service_state (non-mutating status probe) ──────────────────────

  def test_service_state_linux_installed_and_enabled
    with_tmp_dir do |dir|
      # is-enabled invoked → return true (enabled). Capture the argv so
      # we can assert it is the read-only `is-enabled` query, never a
      # mutating enable/start.
      seen = []
      runner = ->(argv) { seen << argv; true }
      installer = TestInstaller.new(host_os: "linux", home: dir,
                                    systemctl_available: true, runner: runner)
      FileUtils.mkdir_p(File.dirname(installer.target_path))
      File.write(installer.target_path, "unit\n")

      state = installer.service_lifecycle_state

      assert_equal "linux", state["platform"]
      assert_equal installer.target_path, state["unit_path"]
      assert state["service_installed"], "unit file exists on disk → installed=true"
      assert state["service_enabled"], "is-enabled exit 0 → enabled=true"
      assert state["service_running"], "is-active exit 0 → running=true"
      assert state["service_manager_available"]
      assert_equal [ %w[systemctl --user is-enabled hive-test],
                     %w[systemctl --user is-active --quiet hive-test] ], seen,
                   "service state must use read-only manager queries only"
    end
  end

  def test_service_state_linux_not_installed_and_disabled
    with_tmp_dir do |dir|
      runner = ->(_argv) { false }
      installer = TestInstaller.new(host_os: "linux", home: dir,
                                    systemctl_available: true, runner: runner)

      state = installer.service_lifecycle_state

      refute state["service_installed"], "no unit file on disk → installed=false"
      refute state["service_enabled"], "is-enabled non-zero → enabled=false"
      refute state["service_running"]
    end
  end

  def test_service_state_linux_disabled_when_systemctl_unavailable
    with_tmp_dir do |dir|
      # systemctl missing → enabled must be false and the runner must
      # never be called (no probe to a non-existent service manager).
      called = false
      runner = ->(_argv) { called = true }
      installer = TestInstaller.new(host_os: "linux", home: dir,
                                    systemctl_available: false, runner: runner)

      state = installer.service_lifecycle_state

      refute state["service_enabled"]
      refute state["service_running"]
      refute state["service_manager_available"]
      refute called, "must not probe systemctl when it is unavailable"
    end
  end

  def test_linux_manager_availability_probes_show_environment_when_not_injected
    with_tmp_dir do |dir|
      seen = []
      installer = TestInstaller.new(host_os: "linux", home: dir, runner: ->(argv) { seen << argv; true })
      installer.define_singleton_method(:systemctl_available?) { true }

      assert installer.service_manager_available?
      assert_includes seen, %w[systemctl --user show-environment]
    end
  end

  def test_linux_manager_availability_stops_when_systemctl_is_missing
    with_tmp_dir do |dir|
      called = false
      installer = TestInstaller.new(host_os: "linux", home: dir, runner: ->(_argv) { called = true })
      installer.define_singleton_method(:systemctl_available?) { false }

      refute installer.service_manager_available?
      refute called
    end
  end

  def test_service_state_macos_uses_launchctl_list
    with_tmp_dir do |dir|
      seen = []
      runner = ->(argv) { seen << argv; true }
      installer = TestInstaller.new(host_os: "darwin", home: dir, runner: runner,
                                    launchctl_available: true)

      state = installer.service_lifecycle_state

      assert_equal "macos", state["platform"]
      assert state["service_enabled"], "launchctl list exit 0 → loaded → enabled=true"
      assert state["service_running"]
      assert_equal [ %w[launchctl list local.hive-test],
                     %w[launchctl list local.hive-test] ], seen,
                   "macOS probe must be the read-only launchctl list query"
    end
  end

  def test_service_state_macos_disabled_when_launchctl_unavailable
    with_tmp_dir do |dir|
      # launchctl missing → enabled must be false and the runner must never
      # be probed, mirroring the systemctl-unavailable guard so a probe that
      # could not run never reports a confident-but-wrong enabled=true.
      called = false
      runner = ->(_argv) { called = true }
      installer = TestInstaller.new(host_os: "darwin", home: dir, runner: runner,
                                    launchctl_available: false)

      state = installer.service_lifecycle_state

      refute state["service_enabled"]
      refute state["service_running"]
      refute state["service_manager_available"]
      refute called, "must not probe launchctl when it is unavailable"
    end
  end

  def test_service_state_macos_detects_launchctl_via_path_lookup
    with_tmp_dir do |dir|
      # With no injected launchctl_available flag, the guard falls back to a
      # PATH lookup for launchctl. Stub `which` so the probe runs and the
      # read-only launchctl list query is issued.
      seen = []
      runner = ->(argv) { seen << argv; true }
      installer = TestInstaller.new(host_os: "darwin", home: dir, runner: runner)
      installer.define_singleton_method(:which) { |name| name == "launchctl" ? "/bin/launchctl" : nil }

      state = installer.service_lifecycle_state

      assert state["service_enabled"], "launchctl present + list exit 0 → enabled=true"
      assert_equal [ %w[launchctl list local.hive-test],
                     %w[launchctl list local.hive-test] ], seen
    end
  end

  def test_macos_install_is_idempotent_when_unchanged_job_is_already_loaded
    with_tmp_dir do |dir|
      calls = []
      installer = TestInstaller.new(
        host_os: "darwin", home: dir, launchctl_available: true,
        runner: lambda do |argv|
          calls << argv
          argv == %w[launchctl list local.hive-test]
        end
      )
      FileUtils.mkdir_p(File.dirname(installer.target_path))
      File.write(installer.target_path, TestInstaller::UNIT_BODY)

      outcome = installer.install!(autostart: true)

      assert_equal :unchanged, outcome.kind
      assert calls.any?, "planning, revalidation, and final observation must query launchd"
      assert calls.all? { |argv| argv == %w[launchctl list local.hive-test] },
             "an unchanged loaded plist may be observed repeatedly but must remain read-only"
      refute calls.any? { |argv| argv[0, 2] == %w[launchctl load] },
             "an unchanged loaded plist must not be loaded a second time"
    end
  end

  def test_macos_lifecycle_distinguishes_loaded_from_running_job
    with_tmp_dir do |dir|
      installer = TestInstaller.new(
        host_os: "darwin", home: dir, launchctl_available: true,
        runner: ->(_argv) { true },
        status_reader: ->(_argv) { [ "state = waiting\n", true ] }
      )

      state = installer.service_lifecycle_state

      assert state["service_enabled"], "loaded job remains enabled"
      refute state["service_running"], "loaded-but-waiting job must not be called running"
    end
  end

  def test_service_state_unsupported_platform
    installer = TestInstaller.new(host_os: "sunos", runner: ->(_argv) { true })

    state = installer.service_lifecycle_state

    assert_equal "unsupported", state["platform"]
    assert_nil state["unit_path"]
    refute state["service_installed"]
    refute state["service_enabled"]
    refute state["service_running"]
    refute state["service_manager_available"]
    refute installer.service_manager_available?
    refute installer.send(:manager_query_available?)
  end

  def test_user_service_diagnostics_are_rendered_by_the_adapter
    with_tmp_dir do |dir|
      installer = build(dir)
      path = installer.target_path

      installer.send(
        :record_user_service_messages,
        Hive::UserService::Result.new(:stale, diagnostics: [ :stale_plan ]),
        path: path
      )
      installer.send(
        :record_user_service_messages,
        Hive::UserService::Result.new(:unsafe_path, diagnostics: [ :unsafe_unit_path ]),
        path: path
      )

      assert installer.messages.any? { |message| message.include?("changed after it was inspected") }
      assert installer.messages.any? { |message| message.include?("refusing unsafe test unit path") }
    end
  end

  def test_launchd_label_matches_service_name
    installer = TestInstaller.new(host_os: "darwin")
    assert_equal "local.hive-test", installer.launchd_label
  end

  # ── abstract subclass hooks ────────────────────────────────────────
  # A bare subclass that overrides NOTHING must raise NotImplementedError
  # for every identity/render hook, so a half-built subclass fails loudly
  # rather than rendering a malformed unit. `upgrade_restart_warning`
  # defaults to nil (the bot has no long stop drain to warn about).
  class BareInstaller < Hive::Commands::ServiceInstaller::Base
  end

  def test_abstract_hooks_raise_not_implemented
    installer = BareInstaller.new(host_os: "linux")

    %i[service_name cli_label service_noun unit_noun
       render_systemd render_launchd].each do |hook|
      error = assert_raises(NotImplementedError, "#{hook} must raise on the bare base") do
        installer.public_send(hook)
      end
      assert_match(/must define ##{hook}/, error.message)
    end
  end

  # target_path is derived, not abstract: `<service_name>.service` under
  # systemd-user on Linux, `local.<service_name>.plist` under LaunchAgents
  # on macOS, nil on unsupported hosts. A bare subclass still fails loudly
  # because the derivation reads `service_name`.
  def test_target_path_derives_from_service_name_per_platform
    assert_raises(NotImplementedError) { BareInstaller.new(host_os: "linux").target_path }
    assert_nil BareInstaller.new(host_os: "freebsd14").target_path
  end

  def test_upgrade_restart_warning_defaults_to_nil
    installer = BareInstaller.new(host_os: "linux")
    assert_nil installer.upgrade_restart_warning
  end

  # ── Outcome value object ───────────────────────────────────────────────

  def test_outcome_rejects_unknown_kind_loudly
    # An unmapped outcome kind must raise in the constructor rather than
    # silently degrading to a false-error envelope downstream (the failure
    # mode the old else-less case mapping allowed).
    error = assert_raises(ArgumentError) do
      Hive::Commands::ServiceInstaller::Outcome.new(:bogus)
    end
    assert_match(/unknown install outcome :bogus/, error.message)
  end

  def test_outcome_wire_mapping_and_success_classification
    require "hive/commands/service_installer/outcome"
    outcome_class = Hive::Commands::ServiceInstaller::Outcome

    assert_equal "unsupported", outcome_class.new(:autostart_unavailable).wire_outcome,
                 ":autostart_unavailable collapses to the wire `unsupported` success outcome"
    assert outcome_class.new(:written).success?
    assert outcome_class.new(:autostart_unavailable).success?
    refute outcome_class.new(:drifted).success?
    assert outcome_class.new(:drifted).drifted?
    assert outcome_class.new(:failed).failed?

    upgraded = outcome_class.new(:upgraded, backup_path: "/tmp/x.bak", restarted: true)
    assert_equal "/tmp/x.bak", upgraded.backup_path
    assert upgraded.restarted
  end
end
