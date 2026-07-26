require "test_helper"
require "hive/web/browser_bundle"

class WebBrowserBundleTest < Minitest::Test
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
end
