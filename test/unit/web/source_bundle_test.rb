require "test_helper"
require "socket"
require "hive/web/source_bundle"

class WebSourceBundleTest < Minitest::Test
  include HiveTestHelper

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

  def test_default_initialization_and_missing_lockfile_error
    with_source do |source|
      bundle = Hive::Web::SourceBundle.new(source_root: source)
      assert_match(/\A[0-9a-f]{64}\z/, bundle.cache_key(
        {
          "root" => { "sha256" => "a", "mode" => 0o644 },
          "web" => { "sha256" => "b", "mode" => 0o644 }
        }
      ))

      missing = File.join(source, "missing.lock")
      error = assert_raises(Hive::Web::SourceBundle::BootstrapError) do
        bundle.send(:lock_digest, missing)
      end
      assert_match(/dependency file is missing/, error.message)
    end
  end

  def test_foreign_cache_directory_and_symlink_lock_are_rejected
    with_source do |source|
      Dir.mktmpdir("hive-source-cache") do |cache|
        bundle = Hive::Web::SourceBundle.new(source_root: source, cache_root: cache)
        real_lstat = File.method(:lstat)
        foreign = Struct.new(:symlink?, :directory?, :uid).new(false, true, Process.uid + 1)
        replacement = ->(path) { path == cache ? foreign : real_lstat.call(path) }
        error = with_replaced_singleton_method(File, :lstat, replacement) do
          assert_raises(Hive::Web::SourceBundle::OwnershipError) do
            bundle.send(:ensure_owned_directory!, cache)
          end
        end
        assert_match(/owned by uid/, error.message)

        target = File.join(cache, "target")
        File.write(target, "")
        File.symlink(target, File.join(cache, ".abc.lock"))
        error = assert_raises(Hive::Web::SourceBundle::OwnershipError) do
          bundle.send(:with_cache_lock, "abc") { flunk "lock should not yield" }
        end
        assert_match(/lock must not be a symlink/, error.message)
      end
    end
  end

  def test_population_wraps_system_errors_and_rejects_lockfile_mutation
    with_source do |source|
      Dir.mktmpdir("hive-source-cache") do |cache|
        bundle = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache,
          runner: ->(*) { raise Errno::EACCES, "bundle" },
          source_validator: ->(*) { "a" * 40 }
        )
        error = assert_raises(Hive::Web::SourceBundle::BootstrapError) do
          bundle.ensure!
        end
        assert_match(/population failed/, error.message)

        mutated = false
        bundle = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache,
          runner: lambda do |_argv, env, **|
            FileUtils.mkdir_p(env.fetch("BUNDLE_PATH"))
            unless mutated
              mutated = true
              File.write(File.join(source, "Gemfile.lock"), "changed\n")
            end
            true
          end,
          source_validator: ->(*) { "a" * 40 }
        )
        error = assert_raises(Hive::Web::SourceBundle::BootstrapError) do
          bundle.ensure!
        end
        assert_match(/changed authenticated lockfile/, error.message)
      end
    end
  end

  def test_default_runner_and_locked_bundler_error_paths
    with_source do |source|
      bundle = Hive::Web::SourceBundle.new(source_root: source)
      assert bundle.send(
        :default_runner, [ RbConfig.ruby, "-e", "exit 0" ],
        {}, chdir: source
      )

      bundle.define_singleton_method(:locked_bundler_version) { "2.7.2" }
      error = with_replaced_singleton_method(
        Gem, :bin_path, ->(*) { File.join(source, "missing-bundle") }
      ) do
        assert_raises(Hive::Web::SourceBundle::BootstrapError) do
          bundle.send(:locked_bundler_executable)
        end
      end
      assert_match(/executable is unavailable/, error.message)

      error = with_replaced_singleton_method(
        Gem, :bin_path, ->(*) { raise Gem::GemNotFoundException, "missing" }
      ) do
        assert_raises(Hive::Web::SourceBundle::BootstrapError) do
          bundle.send(:locked_bundler_executable)
        end
      end
      assert_match(/install Bundler 2\.7\.2/, error.message)

      FileUtils.rm_f(File.join(source, "web", "Gemfile.lock"))
      error = assert_raises(Hive::Web::SourceBundle::BootstrapError) do
        Hive::Web::SourceBundle.new(source_root: source).send(:locked_bundler_version)
      end
      assert_match(/dependency file is missing/, error.message)
    end
  end

  def test_invalid_cache_manifest_and_quarantine_ownership_errors
    with_source do |source|
      Dir.mktmpdir("hive-source-cache") do |cache|
        now = Time.utc(2026, 7, 26, 3)
        bundle = Hive::Web::SourceBundle.new(
          source_root: source, cache_root: cache, clock: -> { now }
        )
        destination = File.join(cache, "entry")
        FileUtils.mkdir_p(destination)
        File.write(File.join(destination, "manifest.json"), "{")
        refute bundle.send(
          :cache_valid?, destination, "key",
          {
            "root" => { "sha256" => "a", "mode" => 0o644 },
            "web" => { "sha256" => "b", "mode" => 0o644 }
          }
        )

        symlink = File.join(cache, "symlink")
        target = File.join(cache, "target")
        FileUtils.mkdir_p(target)
        File.symlink(target, symlink)
        error = assert_raises(Hive::Web::SourceBundle::OwnershipError) do
          bundle.send(:quarantine!, symlink)
        end
        assert_match(/must not be a symlink/, error.message)

        owned = File.join(cache, "owned")
        FileUtils.mkdir_p(owned)
        real_lstat = File.method(:lstat)
        foreign = Struct.new(:symlink?, :uid).new(false, Process.uid + 1)
        replacement = ->(path) { path == owned ? foreign : real_lstat.call(path) }
        error = with_replaced_singleton_method(File, :lstat, replacement) do
          assert_raises(Hive::Web::SourceBundle::OwnershipError) do
            bundle.send(:quarantine!, owned)
          end
        end
        assert_match(/foreign ownership/, error.message)

        bundle.send(:quarantine!, owned)
        assert Dir.glob("#{owned}.corrupt-20260726T030000Z-*").one?
      end
    end
  end

  def test_source_validation_accepts_exact_clean_git_root_and_rejects_dirty_or_missing
    with_source do |source|
      system("git", "init", "-q", source) or flunk "git init failed"
      system("git", "-C", source, "add", ".") or flunk "git add failed"
      system(
        "git", "-C", source, "-c", "user.name=Hive Test",
        "-c", "user.email=hive@example.test", "commit", "-qm", "fixture"
      ) or flunk "git commit failed"
      bundle = Hive::Web::SourceBundle.new(source_root: source)

      sha = bundle.send(:validate_source!, source)
      assert_match(/\A[0-9a-f]{40}\z/, sha)

      File.write(File.join(source, "dirty.txt"), "dirty")
      error = assert_raises(Hive::Web::SourceBundle::BootstrapError) do
        bundle.send(:validate_source!, source)
      end
      assert_match(/worktree is dirty/, error.message)

      error = assert_raises(Hive::Web::SourceBundle::BootstrapError) do
        bundle.send(:validate_source!, File.join(source, "missing"))
      end
      assert_match(/worktree is unavailable/, error.message)
    end
  end

  def test_source_validation_reports_git_identity_and_probe_failures
    with_source do |source|
      bundle = Hive::Web::SourceBundle.new(source_root: source)
      status = ->(success) { Struct.new(:success?).new(success) }
      scenarios = [
        [
          [ [ "", "not git", status.call(false) ] ],
          /not a Git worktree/
        ],
        [
          [ [ "/tmp\n", "", status.call(true) ] ],
          /does not match/
        ],
        [
          [
            [ "#{source}\n", "", status.call(true) ],
            [ "", "no head", status.call(false) ]
          ],
          /HEAD is unavailable/
        ],
        [
          [
            [ "#{source}\n", "", status.call(true) ],
            [ "bad\n", "", status.call(true) ]
          ],
          /HEAD is invalid/
        ],
        [
          [
            [ "#{source}\n", "", status.call(true) ],
            [ "#{'a' * 40}\n", "", status.call(true) ],
            [ "", "status failed", status.call(false) ]
          ],
          /cleanliness check failed/
        ]
      ]

      scenarios.each do |responses, message|
        error = with_replaced_singleton_method(
          Open3, :capture3, ->(*) { responses.shift }
        ) do
          assert_raises(Hive::Web::SourceBundle::BootstrapError) do
            bundle.send(:validate_source!, source)
          end
        end
        assert_match message, error.message
      end

      link = "#{source}-link"
      File.symlink(source, link)
      error = assert_raises(Hive::Web::SourceBundle::OwnershipError) do
        bundle.send(:validate_source!, link)
      end
      assert_match(/must not be a symlink/, error.message)
    ensure
      FileUtils.rm_f(link) if link
    end
  end

  def test_source_validation_rejects_foreign_ownership_and_cache_sealing_rejects_special_entries
    with_source do |source|
      bundle = Hive::Web::SourceBundle.new(source_root: source)
      real_lstat = File.method(:lstat)
      foreign = Struct.new(:symlink?, :uid).new(false, Process.uid + 1)
      replacement = ->(path) { path == source ? foreign : real_lstat.call(path) }
      error = with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(Hive::Web::SourceBundle::OwnershipError) do
          bundle.send(:validate_source!, source)
        end
      end
      assert_match(/foreign ownership/, error.message)

      Dir.mktmpdir("hive-source-seal") do |root|
        socket = UNIXServer.new(File.join(root, "socket"))
        error = assert_raises(Hive::Web::SourceBundle::OwnershipError) do
          bundle.send(:seal_cache!, root)
        end
        assert_match(/unsupported entry/, error.message)
      ensure
        socket&.close
      end
    end
  end
end
