require "test_helper"
require "socket"
require "hive/web/browser_bundle"

class WebBrowserBundleCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Bundle = Hive::Web::BrowserBundle

  def test_package_metadata_must_be_regular_present_json_and_exactly_pinned
    Dir.mktmpdir("hive-browser-package-gaps") do |root|
      bundle = Bundle.new(package_root: root)
      missing = assert_raises(Bundle::BootstrapError) do
        bundle.send(:package_digest, File.join(root, "missing"))
      end
      assert_match(/missing/, missing.message)

      directory = File.join(root, "package.json")
      Dir.mkdir(directory)
      irregular = assert_raises(Bundle::BootstrapError) do
        bundle.send(:package_digest, directory)
      end
      assert_match(/regular/, irregular.message)
      Dir.rmdir(directory)

      File.write(directory, JSON.generate("dependencies" => { "agent-browser" => "latest" }))
      assert_raises(Bundle::BootstrapError) { bundle.send(:package_version) }
      File.write(directory, "{")
      assert_raises(Bundle::BootstrapError) { bundle.send(:package_version) }
    end
  end

  def test_node_and_npm_probe_failures_are_normalized
    bundle = Bundle.new(environment: { "PATH" => "/bin" })
    failed = Struct.new(:success?).new(false)
    with_replaced_singleton_method(Open3, :capture3, ->(*) { [ "", "no node", failed ] }) do
      assert_raises(Bundle::BootstrapError) { bundle.send(:probe_tools!) }
      assert_raises(Bundle::BootstrapError) { bundle.send(:probe_npm!) }
    end

    with_replaced_singleton_method(Open3, :capture3, ->(*) { raise Errno::ENOENT, "missing" }) do
      assert_raises(Bundle::BootstrapError) { bundle.send(:probe_tools!) }
      assert_raises(Bundle::BootstrapError) { bundle.send(:probe_npm!) }
    end
  end

  def test_cache_population_normalizes_filesystem_failure_and_default_runner_works
    with_package do |package|
      Dir.mktmpdir("hive-browser-cache-gaps") do |cache|
        bundle = Bundle.new(
          package_root: package, cache_root: cache,
          runner: ->(*) { raise Errno::EIO, "disk" }, tool_probe: -> { "v22.0.0" }
        )
        bundle.define_singleton_method(:probe_npm!) { true }
        assert_raises(Bundle::BootstrapError) { bundle.ensure! }

        assert bundle.send(
          :default_runner, [ RbConfig.ruby, "-e", "exit" ], {}, chdir: cache
        )
      end
    end
  end

  def test_native_binary_mapping_rejects_unknown_platforms
    bundle = Bundle.new
    original_cpu = RbConfig::CONFIG.fetch("host_cpu")
    original_os = RbConfig::CONFIG.fetch("host_os")
    begin
      RbConfig::CONFIG["host_cpu"] = "arm64"
      RbConfig::CONFIG["host_os"] = "linux"
      assert_equal "agent-browser-linux-arm64", bundle.send(:native_binary_name)

      RbConfig::CONFIG["host_cpu"] = "mystery"
      assert_raises(Bundle::BootstrapError) { bundle.send(:native_binary_name) }

      RbConfig::CONFIG["host_cpu"] = "x86_64"
      RbConfig::CONFIG["host_os"] = "solaris"
      assert_raises(Bundle::BootstrapError) { bundle.send(:native_binary_name) }
    ensure
      RbConfig::CONFIG["host_cpu"] = original_cpu
      RbConfig::CONFIG["host_os"] = original_os
    end
  end

  def test_browser_discovery_supports_windows_and_normalizes_glob_errors
    Dir.mktmpdir("hive-browser-discovery") do |root|
      bundle = Bundle.new
      original_os = RbConfig::CONFIG.fetch("host_os")
      begin
        RbConfig::CONFIG["host_os"] = "mingw"
        chrome = File.join(root, "chrome.exe")
        File.write(chrome, "fixture")
        assert_equal chrome, bundle.send(:populated_browser_executable, root)
      ensure
        RbConfig::CONFIG["host_os"] = original_os
      end

      with_replaced_singleton_method(Dir, :glob, ->(*) { raise Errno::EIO }) do
        assert_nil bundle.send(:populated_browser_executable, root)
      end
      assert_nil bundle.send(:populated_browser_executable, File.join(root, "missing"))
    end
  end

  def test_cached_browser_path_is_direct_owned_executable_and_confined
    Dir.mktmpdir("hive-browser-cached-path") do |root|
      bundle = Bundle.new
      assert_raises(Bundle::OwnershipError) do
        bundle.send(:cached_browser_executable, root, "../escape")
      end
      assert_nil bundle.send(:cached_browser_executable, root, "missing")

      candidate = File.join(root, "chrome")
      File.write(candidate, "fixture")
      assert_raises(Bundle::OwnershipError) do
        bundle.send(:cached_browser_executable, root, "chrome")
      end
      FileUtils.chmod(0o700, candidate)

      realpath = File.method(:realpath)
      replacement = lambda do |path|
        path == candidate ? "/outside/chrome" : realpath.call(path)
      end
      with_replaced_singleton_method(File, :realpath, replacement) do
        assert_raises(Bundle::OwnershipError) do
          bundle.send(:cached_browser_executable, root, "chrome")
        end
      end
    end
  end

  def test_quarantine_rejects_symlink_and_foreign_entries_then_renames_owned_corruption
    Dir.mktmpdir("hive-browser-quarantine") do |root|
      bundle = Bundle.new(clock: -> { Time.utc(2026, 8, 14) })
      destination = File.join(root, "cache")
      target = File.join(root, "target")
      File.write(target, "target")
      File.symlink(target, destination)
      assert_raises(Bundle::OwnershipError) { bundle.send(:quarantine!, destination) }
      File.unlink(destination)

      Dir.mkdir(destination)
      real_lstat = File.method(:lstat)
      foreign = Struct.new(:symlink?, :uid).new(false, Process.uid + 1)
      replacement = ->(path) { path == destination ? foreign : real_lstat.call(path) }
      with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(Bundle::OwnershipError) { bundle.send(:quarantine!, destination) }
      end

      bundle.send(:quarantine!, destination)
      refute_path_exists destination
      assert_equal 1, Dir.glob("#{destination}.corrupt-*").length
      assert_nil bundle.send(:quarantine!, File.join(root, "missing"))

      default_clock = Bundle.new
      owned = File.join(root, "default-clock")
      Dir.mkdir(owned)
      default_clock.send(:quarantine!, owned)
      assert_equal 1, Dir.glob("#{owned}.corrupt-*").length
    end
  end

  def test_cache_sealing_rejects_unsupported_entries
    Dir.mktmpdir("hive-browser-seal-socket") do |root|
      socket = UNIXServer.new(File.join(root, "socket"))
      bundle = Bundle.new
      assert_raises(Bundle::OwnershipError) { bundle.send(:seal_cache!, root) }
    ensure
      socket&.close
    end
  end

  private

  def with_package
    Dir.mktmpdir("hive-browser-package-gaps") do |root|
      File.write(File.join(root, "package.json"), JSON.generate(
        "dependencies" => { "agent-browser" => "0.34.0" }
      ))
      File.write(File.join(root, "package-lock.json"), JSON.generate("lockfileVersion" => 3))
      yield root
    end
  end
end
