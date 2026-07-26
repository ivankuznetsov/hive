require "test_helper"
require "hive/web/source_bundle"

class WebSourceBundleTest < Minitest::Test
  def with_source
    Dir.mktmpdir("hive-source-bundle") do |root|
      FileUtils.mkdir_p(File.join(root, "web", "config"))
      File.write(File.join(root, "Gemfile.lock"), "root-lock\n")
      File.write(
        File.join(root, "web", "Gemfile.lock"),
        "web-lock\n\nBUNDLED WITH\n   2.7.2\n"
      )
      File.write(File.join(root, "web", "Gemfile"), "source 'https://rubygems.org'\n")
      File.write(File.join(root, "web", "config", "application.rb"), "# app\n")
      yield root
    end
  end

  def test_populates_once_and_reuses_the_lockfile_keyed_cache
    with_source do |source|
      Dir.mktmpdir("hive-source-cache") do |cache|
        calls = 0
        runner = lambda do |argv, env, chdir:|
          calls += 1
          assert_equal File.join(source, "web"), chdir
          assert_equal RbConfig.ruby, argv.fetch(0)
          assert_equal Gem.bin_path("bundler", "bundle", "= 2.7.2"), argv.fetch(1)
          assert_equal %w[install --jobs 4 --retry 2], argv.drop(2)
          FileUtils.mkdir_p(env.fetch("BUNDLE_PATH"))
          File.write(File.join(env.fetch("BUNDLE_PATH"), "installed"), "ok")
          true
        end
        bundle = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache, runner: runner,
          source_validator: ->(*) { "a" * 40 }
        )

        first = bundle.ensure!
        second = bundle.ensure!

        assert_equal first.cache_key, second.cache_key
        assert_equal first.bundle_path, second.bundle_path
        assert_equal 1, calls
        assert_equal "a" * 40, first.source_sha
      end
    end
  end

  def test_changed_lockfile_gets_a_different_cache_key
    with_source do |source|
      Dir.mktmpdir("hive-source-cache") do |cache|
        runner = lambda do |_argv, env, **|
          FileUtils.mkdir_p(env.fetch("BUNDLE_PATH"))
          true
        end
        first = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache, runner: runner,
          source_validator: ->(*) { "a" * 40 }
        ).ensure!
        File.write(
          File.join(source, "web", "Gemfile.lock"),
          "web-lock-2\n\nBUNDLED WITH\n   2.7.2\n"
        )
        second = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache, runner: runner,
          source_validator: ->(*) { "a" * 40 }
        ).ensure!

        refute_equal first.cache_key, second.cache_key
      end
    end
  end

  def test_corrupt_cache_is_quarantined_and_rebuilt
    with_source do |source|
      Dir.mktmpdir("hive-source-cache") do |cache|
        calls = 0
        runner = lambda do |_argv, env, **|
          calls += 1
          FileUtils.mkdir_p(env.fetch("BUNDLE_PATH"))
          true
        end
        bundle = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache, runner: runner,
          source_validator: ->(*) { "a" * 40 }
        )
        entry = bundle.ensure!
        manifest = File.join(File.dirname(entry.bundle_path), "manifest.json")
        File.chmod(0o600, manifest)
        File.write(manifest, "{}")

        rebuilt = bundle.ensure!

        assert_equal 2, calls
        assert File.file?(File.join(File.dirname(rebuilt.bundle_path), "manifest.json"))
        assert Dir.glob(File.join(cache, "#{entry.cache_key}.corrupt-*")).any?
      end
    end
  end

  def test_failed_or_offline_install_does_not_publish_partial_cache
    with_source do |source|
      Dir.mktmpdir("hive-source-cache") do |cache|
        bundle = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache,
          runner: ->(*) { false },
          source_validator: ->(*) { "a" * 40 }
        )

        error = assert_raises(Hive::Web::SourceBundle::BootstrapError) { bundle.ensure! }

        assert_match(/bundle install failed/, error.message)
        refute Dir.glob(File.join(cache, "*", "manifest.json")).any?
      end
    end
  end

  def test_missing_locked_bundler_version_fails_before_install
    with_source do |source|
      Dir.mktmpdir("hive-source-cache") do |cache|
        File.write(File.join(source, "web", "Gemfile.lock"), "web-lock\n")
        bundle = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache,
          runner: ->(*) { flunk "runner must not start without a locked Bundler" },
          source_validator: ->(*) { "a" * 40 }
        )

        error = assert_raises(Hive::Web::SourceBundle::BootstrapError) { bundle.ensure! }

        assert_match(/BUNDLED WITH/, error.message)
      end
    end
  end
end
