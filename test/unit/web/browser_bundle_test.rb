require "test_helper"
require "socket"
require "hive/web/browser_bundle"

class WebBrowserBundleTest < Minitest::Test
  include HiveTestHelper

  def with_source
    Dir.mktmpdir("hive-browser-source") do |root|
      web = File.join(root, "web")
      FileUtils.mkdir_p(web)
      File.write(File.join(web, "package.json"), JSON.generate(
        "dependencies" => { "playwright" => "1.60.0" }
      ))
      File.write(File.join(web, "package-lock.json"), JSON.generate(
        "lockfileVersion" => 3
      ))
      yield root
    end
  end

  def test_populates_once_and_reuses_the_pinned_browser_cache
    with_source do |source|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        calls = []
        runner = lambda do |argv, env, chdir:|
          calls << argv
          node_modules = File.join(chdir, "node_modules")
          cli = File.join(node_modules, ".bin", "playwright")
          FileUtils.mkdir_p(File.dirname(cli))
          File.write(cli, "#!/bin/sh\n")
          FileUtils.chmod(0o755, cli)
          FileUtils.mkdir_p(File.join(env.fetch("PLAYWRIGHT_BROWSERS_PATH"), "chromium-1234"))
          true
        end
        bundle = Hive::Web::BrowserBundle.new(
          source_root: source,
          cache_root: cache,
          runner: runner,
          tool_probe: -> { "v26.2.0" }
        )

        first = bundle.ensure!
        second = bundle.ensure!

        assert_equal first.cache_key, second.cache_key
        assert_equal 2, calls.length
        assert_equal "1.60.0", JSON.parse(File.read(File.join(source, "web", "package.json")))
                                       .dig("dependencies", "playwright")
        assert File.executable?(first.playwright_cli)
        assert File.directory?(first.browsers_path)
      end
    end
  end

  def test_changed_package_lock_gets_an_isolated_cache_key
    with_source do |source|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        runner = lambda do |_argv, env, chdir:|
          cli = File.join(chdir, "node_modules", ".bin", "playwright")
          FileUtils.mkdir_p(File.dirname(cli))
          File.write(cli, "#!/bin/sh\n")
          FileUtils.chmod(0o755, cli)
          FileUtils.mkdir_p(File.join(env.fetch("PLAYWRIGHT_BROWSERS_PATH"), "chromium-1234"))
          true
        end
        build = lambda do
          Hive::Web::BrowserBundle.new(
            source_root: source, cache_root: cache, runner: runner,
            tool_probe: -> { "v26.2.0" }
          ).ensure!
        end

        first = build.call
        File.write(File.join(source, "web", "package-lock.json"), "{\"lockfileVersion\":3,\"changed\":true}\n")
        second = build.call

        refute_equal first.cache_key, second.cache_key
      end
    end
  end

  def test_failed_install_never_publishes_a_partial_cache
    with_source do |source|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        bundle = Hive::Web::BrowserBundle.new(
          source_root: source,
          cache_root: cache,
          runner: ->(*) { false },
          tool_probe: -> { "v26.2.0" }
        )

        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) { bundle.ensure! }

        assert_match(/npm install failed/, error.message)
        refute Dir.glob(File.join(cache, "*", "manifest.json")).any?
      end
    end
  end

  def test_default_initialization_and_package_metadata_errors
    with_source do |source|
      bundle = Hive::Web::BrowserBundle.new(source_root: source)
      assert_match(/\A[0-9a-f]{64}\z/, bundle.cache_key(
        {
          "package" => { "sha256" => "a", "mode" => 0o644 },
          "package_lock" => { "sha256" => "b", "mode" => 0o644 }
        },
        "v26.2.0"
      ))
      Dir.mktmpdir("hive-browser-default-clock") do |cache|
        corrupt = File.join(cache, "corrupt")
        FileUtils.mkdir_p(corrupt)
        default_clock_bundle = Hive::Web::BrowserBundle.new(
          source_root: source, cache_root: cache
        )
        default_clock_bundle.send(:quarantine!, corrupt)
        assert Dir.glob("#{corrupt}.corrupt-*").one?
      end

      package = File.join(source, "web", "package.json")
      FileUtils.rm_f(package)
      FileUtils.mkdir_p(package)
      error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
        bundle.send(:package_digest, package)
      end
      assert_match(/regular package metadata/, error.message)

      missing = File.join(source, "web", "missing-lock.json")
      error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
        bundle.send(:package_digest, missing)
      end
      assert_match(/dependency file is missing/, error.message)
    end
  end

  def test_tool_probe_requires_supported_node_and_npm
    with_source do |source|
      bundle = Hive::Web::BrowserBundle.new(
        source_root: source, environment: { "PATH" => "/bin" }
      )
      status = ->(success) { Struct.new(:success?).new(success) }

      responses = [
        [ "", "node missing", status.call(false) ]
      ]
      error = with_replaced_singleton_method(
        Open3, :capture3, ->(*) { responses.shift }
      ) do
        assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
          bundle.send(:probe_tools!)
        end
      end
      assert_match(/Node\.js is unavailable/, error.message)

      responses = [ [ "v20.1.0\n", "", status.call(true) ] ]
      error = with_replaced_singleton_method(
        Open3, :capture3, ->(*) { responses.shift }
      ) do
        assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
          bundle.send(:probe_tools!)
        end
      end
      assert_match(/Node\.js 22\+/, error.message)

      responses = [
        [ "v26.2.0\n", "", status.call(true) ],
        [ "", "npm missing", status.call(false) ]
      ]
      error = with_replaced_singleton_method(
        Open3, :capture3, ->(*) { responses.shift }
      ) do
        assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
          bundle.send(:probe_tools!)
        end
      end
      assert_match(/npm is unavailable/, error.message)

      responses = [
        [ "v26.2.0\n", "", status.call(true) ],
        [ "11.0.0\n", "", status.call(true) ]
      ]
      version = with_replaced_singleton_method(
        Open3, :capture3, ->(*) { responses.shift }
      ) { bundle.send(:probe_tools!) }
      assert_equal "v26.2.0", version

      error = with_replaced_singleton_method(
        Open3, :capture3, ->(*) { raise Errno::ENOENT, "node" }
      ) do
        assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
          bundle.send(:probe_tools!)
        end
      end
      assert_match(/tool is unavailable/, error.message)
    end
  end

  def test_foreign_cache_directory_and_symlink_lock_are_rejected
    with_source do |source|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        bundle = Hive::Web::BrowserBundle.new(source_root: source, cache_root: cache)
        real_lstat = File.method(:lstat)
        foreign = Struct.new(:symlink?, :directory?, :uid).new(false, true, Process.uid + 1)
        replacement = ->(path) { path == cache ? foreign : real_lstat.call(path) }

        error = with_replaced_singleton_method(File, :lstat, replacement) do
          assert_raises(Hive::Web::BrowserBundle::OwnershipError) do
            bundle.send(:ensure_owned_directory!, cache)
          end
        end
        assert_match(/owned by uid/, error.message)

        target = File.join(cache, "target")
        File.write(target, "")
        File.symlink(target, File.join(cache, ".abc.lock"))
        error = assert_raises(Hive::Web::BrowserBundle::OwnershipError) do
          bundle.send(:with_cache_lock, "abc") { flunk "lock should not yield" }
        end
        assert_match(/lock must not be a symlink/, error.message)
      end
    end
  end

  def test_population_requires_cli_browser_payload_and_unmodified_packages
    with_source do |source|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        base_options = {
          source_root: source, cache_root: cache,
          tool_probe: -> { "v26.2.0" }
        }
        missing_cli = Hive::Web::BrowserBundle.new(
          **base_options, runner: ->(*) { true }
        )
        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
          missing_cli.ensure!
        end
        assert_match(/CLI was not installed/, error.message)

        no_browser = Hive::Web::BrowserBundle.new(
          **base_options,
          runner: lambda do |_argv, _env, chdir:|
            cli = File.join(chdir, "node_modules", ".bin", "playwright")
            FileUtils.mkdir_p(File.dirname(cli))
            File.write(cli, "#!/bin/sh\n")
            FileUtils.chmod(0o755, cli)
            true
          end
        )
        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
          no_browser.ensure!
        end
        assert_match(/without a Chromium payload/, error.message)

        system_failure = Hive::Web::BrowserBundle.new(
          **base_options, runner: ->(*) { raise Errno::EACCES, "npm" }
        )
        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
          system_failure.ensure!
        end
        assert_match(/population failed/, error.message)

        mutated = false
        mutation = Hive::Web::BrowserBundle.new(
          **base_options,
          runner: lambda do |_argv, env, chdir:|
            cli = File.join(chdir, "node_modules", ".bin", "playwright")
            FileUtils.mkdir_p(File.dirname(cli))
            File.write(cli, "#!/bin/sh\n")
            FileUtils.chmod(0o755, cli)
            FileUtils.mkdir_p(File.join(env.fetch("PLAYWRIGHT_BROWSERS_PATH"), "chromium-1234"))
            unless mutated
              mutated = true
              File.write(File.join(source, "web", "package.json"), "{\"changed\":true}\n")
            end
            true
          end
        )
        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) do
          mutation.ensure!
        end
        assert_match(/changed authenticated package metadata/, error.message)
      end
    end
  end

  def test_default_runner_and_cache_validation_error_paths
    with_source do |source|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        bundle = Hive::Web::BrowserBundle.new(source_root: source, cache_root: cache)
        assert bundle.send(
          :default_runner, [ RbConfig.ruby, "-e", "exit 0" ],
          {}, chdir: source
        )

        destination = File.join(cache, "entry")
        FileUtils.mkdir_p(destination)
        File.write(File.join(destination, "manifest.json"), "{")
        refute bundle.send(
          :cache_valid?, destination, "key",
          {
            "package" => { "sha256" => "a", "mode" => 0o644 },
            "package_lock" => { "sha256" => "b", "mode" => 0o644 }
          },
          "v26.2.0"
        )

        real_children = Dir.method(:children)
        replacement = ->(path) {
          raise Errno::EACCES, path if path == destination

          real_children.call(path)
        }
        assert_equal false, with_replaced_singleton_method(Dir, :children, replacement) {
          bundle.send(:populated_browser_cache?, destination)
        }
      end
    end
  end

  def test_quarantine_rejects_unowned_entries_and_moves_owned_corruption
    with_source do |source|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        now = Time.utc(2026, 7, 26, 3)
        bundle = Hive::Web::BrowserBundle.new(
          source_root: source, cache_root: cache, clock: -> { now }
        )
        symlink = File.join(cache, "symlink")
        target = File.join(cache, "target")
        FileUtils.mkdir_p(target)
        File.symlink(target, symlink)
        error = assert_raises(Hive::Web::BrowserBundle::OwnershipError) do
          bundle.send(:quarantine!, symlink)
        end
        assert_match(/must not be a symlink/, error.message)

        owned = File.join(cache, "owned")
        FileUtils.mkdir_p(owned)
        real_lstat = File.method(:lstat)
        foreign = Struct.new(:symlink?, :uid).new(false, Process.uid + 1)
        replacement = ->(path) { path == owned ? foreign : real_lstat.call(path) }
        error = with_replaced_singleton_method(File, :lstat, replacement) do
          assert_raises(Hive::Web::BrowserBundle::OwnershipError) do
            bundle.send(:quarantine!, owned)
          end
        end
        assert_match(/foreign ownership/, error.message)

        bundle.send(:quarantine!, owned)
        assert Dir.glob("#{owned}.corrupt-20260726T030000Z-*").one?
      end
    end
  end

  def test_cache_sealing_accepts_internal_symlinks_and_rejects_escaping_or_special_entries
    with_source do |source|
      bundle = Hive::Web::BrowserBundle.new(source_root: source)
      Dir.mktmpdir("hive-browser-seal") do |root|
        file = File.join(root, "tool")
        File.write(file, "#!/bin/sh\n")
        FileUtils.chmod(0o755, file)
        File.symlink(file, File.join(root, "internal-link"))

        bundle.send(:seal_cache!, root)
        assert_equal 0o500, File.stat(file).mode & 0o777
      end

      Dir.mktmpdir("hive-browser-seal") do |root|
        File.symlink("/tmp", File.join(root, "escape"))
        error = assert_raises(Hive::Web::BrowserBundle::OwnershipError) do
          bundle.send(:seal_cache!, root)
        end
        assert_match(/escaping symlink/, error.message)
      end

      Dir.mktmpdir("hive-browser-seal") do |root|
        socket_path = File.join(root, "socket")
        socket = UNIXServer.new(socket_path)
        error = assert_raises(Hive::Web::BrowserBundle::OwnershipError) do
          bundle.send(:seal_cache!, root)
        end
        assert_match(/unsupported entry/, error.message)
      ensure
        socket&.close
      end
    end
  end
end
