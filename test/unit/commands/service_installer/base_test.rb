require "test_helper"
require "hive/commands/service_installer/base"

# Direct unit tests for the platform-agnostic mechanics of
# Hive::Commands::ServiceInstaller::Base, exercised through a minimal
# subclass that supplies the identity/render hooks. The daemon and bot
# subclasses inherit these mechanics verbatim; this pins them so a future
# change to the base can't silently regress write_if_safe / atomic_write /
# ruby_shim_dir for both installers at once.
class ServiceInstallerBaseTest < Minitest::Test
  include HiveTestHelper

  # Tiny concrete subclass: supplies just enough to drive the base's
  # generic paths. `render_systemd` returns a fixed body so write_if_safe
  # diffs are deterministic, and `target_path` lives under the test home.
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

    # Expose private mechanics for direct unit testing.
    public :write_if_safe, :atomic_write, :ruby_shim_dir, :build_path_line
  end

  def build(dir, **opts)
    TestInstaller.new(host_os: "linux", home: dir, binary_path: "/tmp/hive",
                      systemctl_available: false, **opts)
  end

  # ── write_if_safe ──────────────────────────────────────────────────

  def test_write_if_safe_writes_new_file
    with_tmp_dir do |dir|
      installer = build(dir)
      path = File.join(dir, "unit.service")

      result = installer.write_if_safe(path, "new-content\n")

      assert_equal :written, result
      assert_equal "new-content\n", File.read(path)
      assert_empty installer.messages
    end
  end

  def test_write_if_safe_unchanged_when_content_matches
    with_tmp_dir do |dir|
      installer = build(dir)
      path = File.join(dir, "unit.service")
      File.write(path, "same\n")

      result = installer.write_if_safe(path, "same\n")

      assert_equal :unchanged, result
      assert_equal "same\n", File.read(path)
      assert_empty installer.messages
    end
  end

  def test_write_if_safe_drifted_without_force_leaves_file_and_warns
    with_tmp_dir do |dir|
      installer = build(dir)
      path = File.join(dir, "unit.service")
      File.write(path, "user-edited\n")

      result = installer.write_if_safe(path, "template\n")

      assert_equal :drifted, result
      assert_equal "user-edited\n", File.read(path),
                   "drift without --force must never overwrite the user's file"
      assert installer.messages.any? { |m| m.include?("test service already exists at #{path}") },
             "drift message must use the subclass service_noun, got: #{installer.messages.inspect}"
      assert installer.messages.any? { |m| m.include?("hive test install --force") },
             "drift message must point at the subclass cli_label --force flow"
    end
  end

  def test_write_if_safe_upgraded_with_force_writes_backup
    with_tmp_dir do |dir|
      installer = build(dir)
      path = File.join(dir, "unit.service")
      File.write(path, "stale\n")

      result = installer.write_if_safe(path, "fresh\n", force: true)

      assert_equal :upgraded, result
      assert_equal "fresh\n", File.read(path)
      backups = Dir["#{path}.bak-*"]
      assert_equal 1, backups.size, "force must back up the prior content exactly once"
      assert_equal "stale\n", File.read(backups.first)
      assert_equal backups.first, installer.instance_variable_get(:@last_backup_path),
                   "write_if_safe must record the backup path so install! can surface it on the Outcome"
      assert installer.messages.any? { |m| m.include?("upgraded existing unit") }
    end
  end

  # ── atomic_write ───────────────────────────────────────────────────

  def test_atomic_write_leaves_no_tmp_file_on_success
    with_tmp_dir do |dir|
      installer = build(dir)
      path = File.join(dir, "nested", "out.txt")

      installer.atomic_write(path, "payload\n")

      assert_equal "payload\n", File.read(path)
      assert_empty Dir["#{path}.tmp.*"], "atomic_write must clean up its tmp file on success"
    end
  end

  def test_atomic_write_cleans_up_tmp_when_rename_fails
    with_tmp_dir do |dir|
      installer = build(dir)
      path = File.join(dir, "out.txt")
      # Force File.rename to blow up so the ensure-clause cleanup runs;
      # the target must be left untouched (no torn write) and no tmp
      # litter remains.
      installer.define_singleton_method(:atomic_write) do |target, content|
        FileUtils.mkdir_p(File.dirname(target))
        tmp = "#{target}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        begin
          File.write(tmp, content)
          raise IOError, "simulated rename failure"
        ensure
          File.unlink(tmp) if File.exist?(tmp)
        end
      end

      assert_raises(IOError) { installer.atomic_write(path, "x") }
      refute File.exist?(path), "failed write must not create the target"
      assert_empty Dir["#{path}.tmp.*"], "tmp must be cleaned up even when rename fails"
    end
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

      state = installer.service_state

      assert_equal "linux", state["platform"]
      assert_equal installer.target_path, state["unit_path"]
      assert state["service_installed"], "unit file exists on disk → installed=true"
      assert state["service_enabled"], "is-enabled exit 0 → enabled=true"
      assert_equal [ %w[systemctl --user is-enabled hive-test] ], seen,
                   "service_enabled? must use the read-only is-enabled query only"
    end
  end

  def test_service_state_linux_not_installed_and_disabled
    with_tmp_dir do |dir|
      runner = ->(_argv) { false }
      installer = TestInstaller.new(host_os: "linux", home: dir,
                                    systemctl_available: true, runner: runner)

      state = installer.service_state

      refute state["service_installed"], "no unit file on disk → installed=false"
      refute state["service_enabled"], "is-enabled non-zero → enabled=false"
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

      state = installer.service_state

      refute state["service_enabled"]
      refute called, "must not probe systemctl when it is unavailable"
    end
  end

  def test_service_state_macos_uses_launchctl_list
    with_tmp_dir do |dir|
      seen = []
      runner = ->(argv) { seen << argv; true }
      installer = TestInstaller.new(host_os: "darwin", home: dir, runner: runner,
                                    launchctl_available: true)

      state = installer.service_state

      assert_equal "macos", state["platform"]
      assert state["service_enabled"], "launchctl list exit 0 → loaded → enabled=true"
      assert_equal [ %w[launchctl list local.hive-test] ], seen,
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

      state = installer.service_state

      refute state["service_enabled"]
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

      state = installer.service_state

      assert state["service_enabled"], "launchctl present + list exit 0 → enabled=true"
      assert_equal [ %w[launchctl list local.hive-test] ], seen
    end
  end

  def test_service_state_unsupported_platform
    installer = TestInstaller.new(host_os: "sunos", runner: ->(_argv) { true })

    state = installer.service_state

    assert_equal "unsupported", state["platform"]
    assert_nil state["unit_path"]
    refute state["service_installed"]
    refute state["service_enabled"]
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

    %i[service_name cli_label service_noun unit_noun target_path
       render_systemd render_launchd].each do |hook|
      error = assert_raises(NotImplementedError, "#{hook} must raise on the bare base") do
        installer.public_send(hook)
      end
      assert_match(/must define ##{hook}/, error.message)
    end
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
