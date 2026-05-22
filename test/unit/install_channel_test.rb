require "test_helper"
require "rbconfig"
require "hive/install_channel"

class InstallChannelTest < Minitest::Test
  include HiveTestHelper

  def test_write_and_read_marker
    with_tmp_dir do |dir|
      path = File.join(dir, "install-channel")
      Hive::InstallChannel.write("bash", path: path)
      assert_equal "bash", Hive::InstallChannel.read(path)
    end
  end

  def test_rejects_unknown_channel
    err = assert_raises(Hive::ConfigError) do
      Hive::InstallChannel.write("pkgsrc", path: "/tmp/unused")
    end
    assert_match(/unknown hive install channel/, err.message)
  end

  def test_detect_fails_closed_on_corrupt_marker
    with_tmp_dir do |dir|
      corrupt = File.join(dir, "corrupt")
      fallback = File.join(dir, "fallback")
      File.write(corrupt, "pkgsrc\n")
      File.write(fallback, "bash\n")

      err = assert_raises(Hive::ConfigError) do
        Hive::InstallChannel.detect(marker_paths: [ corrupt, fallback ])
      end
      assert_match(/invalid install-channel marker/, err.message)
    end
  end

  def test_detect_uses_first_existing_marker
    with_tmp_dir do |dir|
      missing = File.join(dir, "missing")
      brew = File.join(dir, "brew")
      aur = File.join(dir, "aur")
      File.write(brew, "brew\n")
      File.write(aur, "aur\n")

      assert_equal "brew", Hive::InstallChannel.detect(marker_paths: [ missing, brew, aur ])
    end
  end

  def test_detect_falls_back_to_dev
    with_tmp_dir do |dir|
      assert_equal "dev", Hive::InstallChannel.detect(marker_paths: [ File.join(dir, "missing") ])
    end
  end

  def test_detected_prefix_reads_sidecar_for_first_valid_marker
    with_tmp_dir do |dir|
      marker = File.join(dir, "install-channel")
      File.write(marker, "bash\n")
      File.write(File.join(dir, "install-prefix"), "/opt/hive\n")

      assert_equal "/opt/hive", Hive::InstallChannel.detected_prefix(marker_paths: [ marker ])
    end
  end

  # Exercise the prod resolver `default_marker_paths` directly. Tests
  # that injected marker_paths previously skipped this branch — a
  # regression to the OS/Homebrew probe logic could silently return
  # `dev` without anything catching it.
  def test_default_marker_paths_includes_xdg_marker
    paths = Hive::InstallChannel.default_marker_paths
    assert_includes paths, Hive::InstallChannel.marker_path,
                    "default probes must include the canonical XDG marker_path"
    # On non-macOS hosts the brew probes must not appear — preventing
    # a stray HOMEBREW_PREFIX or /usr/local marker from hijacking
    # the install channel.
    unless RbConfig::CONFIG["host_os"] =~ /darwin/i
      assert paths.none? { |p| p.include?("/opt/homebrew/share/hive") },
             "non-macOS hosts must not probe /opt/homebrew markers"
    end
  end
def test_detected_prefix_returns_nil_when_no_marker_is_found
  with_tmp_dir do |dir|
    assert_nil Hive::InstallChannel.detected_prefix(marker_paths: [ File.join(dir, "missing") ])
  end
end

def test_read_prefix_returns_nil_for_missing_or_empty_sidecar
  with_tmp_dir do |dir|
    marker = File.join(dir, "install-channel")

    assert_nil Hive::InstallChannel.read_prefix(marker)

    File.write(File.join(dir, "install-prefix"), "\n")
    assert_nil Hive::InstallChannel.read_prefix(marker)
  end
end

def test_prefix_marker_paths_uses_hive_prefix
  with_tmp_dir do |dir|
    prefix = File.join(dir, "prefix")
    old_prefix = ENV["HIVE_PREFIX"]
    ENV["HIVE_PREFIX"] = prefix

    assert_equal [ File.join(prefix, "hive", "install-channel") ],
                 Hive::InstallChannel.prefix_marker_paths
  ensure
    old_prefix.nil? ? ENV.delete("HIVE_PREFIX") : ENV["HIVE_PREFIX"] = old_prefix
  end
end

def test_homebrew_marker_paths_uses_valid_env_prefix_on_macos
  with_tmp_dir do |dir|
    prefix = File.join(dir, "homebrew")
    brew = File.join(prefix, "bin", "brew")
    FileUtils.mkdir_p(File.dirname(brew))
    File.write(brew, "#!/bin/sh\n")
    File.chmod(0o755, brew)
    old_prefix = ENV["HOMEBREW_PREFIX"]
    ENV["HOMEBREW_PREFIX"] = prefix

    paths = with_replaced_singleton_method(Hive::InstallChannel, :macos?, -> { true }) do
      Hive::InstallChannel.homebrew_marker_paths
    end

    assert_equal File.join(prefix, "share/hive/install-channel"), paths.first
    assert_includes paths, "/opt/homebrew/share/hive/install-channel"
    assert_includes paths, "/usr/local/share/hive/install-channel"
  ensure
    old_prefix.nil? ? ENV.delete("HOMEBREW_PREFIX") : ENV["HOMEBREW_PREFIX"] = old_prefix
  end
end

def test_homebrew_marker_paths_ignores_invalid_env_prefix_on_macos
  old_prefix = ENV["HOMEBREW_PREFIX"]
  ENV["HOMEBREW_PREFIX"] = "/tmp/../homebrew"

  paths = with_replaced_singleton_method(Hive::InstallChannel, :macos?, -> { true }) do
    Hive::InstallChannel.homebrew_marker_paths
  end

  refute_includes paths, "/tmp/../homebrew/share/hive/install-channel"
  assert_includes paths, "/opt/homebrew/share/hive/install-channel"
ensure
  old_prefix.nil? ? ENV.delete("HOMEBREW_PREFIX") : ENV["HOMEBREW_PREFIX"] = old_prefix
end

def test_valid_homebrew_prefix_rejects_relative_paths
  refute Hive::InstallChannel.valid_homebrew_prefix?("relative/homebrew")
end

private

def with_replaced_singleton_method(receiver, name, replacement)
  original = receiver.method(name)
  receiver.define_singleton_method(name, &replacement)
  yield
ensure
  receiver.define_singleton_method(name, original) if original
end
end
