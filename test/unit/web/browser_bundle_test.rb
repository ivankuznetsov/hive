require "test_helper"
require "socket"
require "hive/web/browser_bundle"

class WebBrowserBundleTest < Minitest::Test
  include HiveTestHelper

  def with_package
    Dir.mktmpdir("hive-capture-package") do |root|
      File.write(File.join(root, "package.json"), JSON.generate(
        "dependencies" => { "agent-browser" => "0.34.0" }
      ))
      File.write(File.join(root, "package-lock.json"), JSON.generate(
        "lockfileVersion" => 3
      ))
      yield root
    end
  end

  def populate_runner(calls: [])
    lambda do |argv, env, chdir:|
      calls << argv
      if argv.first == "npm"
        cli = File.join(
          chdir, "node_modules", "agent-browser", "bin",
          Hive::Web::BrowserBundle.new.send(:native_binary_name)
        )
        FileUtils.mkdir_p(File.dirname(cli))
        File.write(cli, "native")
        FileUtils.mkdir_p(File.join(chdir, "node_modules", "agent-browser", "skill-data"))
      else
        browser = File.join(env.fetch("PUPPETEER_CACHE_DIR"), "chrome", "123", "chrome")
        FileUtils.mkdir_p(File.dirname(browser))
        File.write(browser, "browser")
        FileUtils.chmod(0o755, browser)
      end
      true
    end
  end

  def test_populates_once_and_reuses_pinned_agent_browser_and_chrome
    with_package do |package|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        calls = []
        bundle = Hive::Web::BrowserBundle.new(
          package_root: package, cache_root: cache,
          runner: populate_runner(calls: calls), tool_probe: -> { "v22.23.1" }
        )

        first = bundle.ensure!
        bundle.define_singleton_method(:probe_npm!) { flunk "warm cache must not probe npm" }
        bundle.define_singleton_method(:populated_browser_executable) do |_path|
          flunk "warm cache must not recursively scan managed Chrome"
        end
        second = bundle.ensure!

        assert_equal first.cache_key, second.cache_key
        assert_equal 2, calls.length
        assert_equal %w[npm ci --ignore-scripts --no-audit --no-fund], calls.first
        assert_equal "install", calls.last.last
        assert_equal "0.34.0", first.agent_browser_version
        assert File.executable?(first.agent_browser_cli)
        assert File.executable?(first.browser_executable)
        refute_includes first.agent_browser_cli, "playwright"
      end
    end
  end

  def test_changed_lock_gets_an_isolated_cache_key
    with_package do |package|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        build = lambda do
          Hive::Web::BrowserBundle.new(
            package_root: package, cache_root: cache,
            runner: populate_runner, tool_probe: -> { "v22.23.1" }
          ).ensure!
        end
        first = build.call
        File.write(File.join(package, "package-lock.json"), "{\"lockfileVersion\":3,\"changed\":true}\n")
        second = build.call
        refute_equal first.cache_key, second.cache_key
      end
    end
  end

  def test_failed_or_incomplete_install_never_publishes_partial_cache
    with_package do |package|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        failed = Hive::Web::BrowserBundle.new(
          package_root: package, cache_root: cache,
          runner: ->(*) { false }, tool_probe: -> { "v22.23.1" }
        )
        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) { failed.ensure! }
        assert_match(/npm install failed/, error.message)
        refute Dir.glob(File.join(cache, "*", "manifest.json")).any?

        missing = Hive::Web::BrowserBundle.new(
          package_root: package, cache_root: cache,
          runner: ->(*) { true }, tool_probe: -> { "v22.23.1" }
        )
        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) { missing.ensure! }
        assert_match(/native CLI was not installed/, error.message)
      end
    end
  end

  def test_population_requires_managed_chrome_and_unchanged_package_metadata
    with_package do |package|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        no_browser = lambda do |_argv, _env, chdir:|
          cli = File.join(
            chdir, "node_modules", "agent-browser", "bin",
            Hive::Web::BrowserBundle.new.send(:native_binary_name)
          )
          FileUtils.mkdir_p(File.dirname(cli))
          File.write(cli, "native")
          true
        end
        bundle = Hive::Web::BrowserBundle.new(
          package_root: package, cache_root: cache, runner: no_browser,
          tool_probe: -> { "v22.23.1" }
        )
        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) { bundle.ensure! }
        assert_match(/without a managed Chrome payload/, error.message)

        mutated = false
        runner = populate_runner
        mutation = lambda do |argv, env, chdir:|
          result = runner.call(argv, env, chdir: chdir)
          unless mutated
            mutated = true
            File.write(File.join(package, "package.json"), "{\"changed\":true}\n")
          end
          result
        end
        bundle = Hive::Web::BrowserBundle.new(
          package_root: package, cache_root: cache, runner: mutation,
          tool_probe: -> { "v22.23.1" }
        )
        error = assert_raises(Hive::Web::BrowserBundle::BootstrapError) { bundle.ensure! }
        assert_match(/changed authenticated package metadata/, error.message)
      end
    end
  end

  def test_tool_probe_only_needs_node_for_authenticated_package_extraction
    with_package do |package|
      bundle = Hive::Web::BrowserBundle.new(
        package_root: package, environment: { "PATH" => "/bin" }
      )
      status = ->(success) { Struct.new(:success?).new(success) }
      responses = [ [ "v16.1.0\n", "", status.call(true) ] ]
      error = with_replaced_singleton_method(Open3, :capture3, ->(*) { responses.shift }) do
        assert_raises(Hive::Web::BrowserBundle::BootstrapError) { bundle.send(:probe_tools!) }
      end
      assert_match(/Node\.js 18\+/, error.message)

      responses = [
        [ "v20.19.0\n", "", status.call(true) ],
        [ "10.0.0\n", "", status.call(true) ]
      ]
      version = with_replaced_singleton_method(Open3, :capture3, ->(*) { responses.shift }) do
        bundle.send(:probe_tools!)
      end
      assert_equal "v20.19.0", version
    end
  end

  def test_foreign_cache_symlink_lock_and_escaping_entries_are_rejected
    with_package do |package|
      Dir.mktmpdir("hive-browser-cache") do |cache|
        bundle = Hive::Web::BrowserBundle.new(package_root: package, cache_root: cache)
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

      Dir.mktmpdir("hive-browser-seal") do |root|
        File.symlink("/tmp", File.join(root, "escape"))
        bundle = Hive::Web::BrowserBundle.new(package_root: package)
        error = assert_raises(Hive::Web::BrowserBundle::OwnershipError) do
          bundle.send(:seal_cache!, root)
        end
        assert_match(/escaping symlink/, error.message)
      end
    end
  end

  def test_shipped_package_is_exactly_pinned_and_part_of_gem_files
    package = Hive::Web::BrowserBundle::PACKAGE_ROOT
    assert_equal "0.34.0", JSON.parse(File.read(File.join(package, "package.json")))
                                   .dig("dependencies", "agent-browser")
    gemspec = Gem::Specification.load(File.expand_path("../../../hive.gemspec", __dir__))
    assert_includes gemspec.files, "lib/hive/assets/capture-tools/package.json"
    assert_includes gemspec.files, "lib/hive/assets/capture-tools/package-lock.json"
  end
end
