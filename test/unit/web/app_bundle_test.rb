require "test_helper"
require "rubygems/package"
require "zlib"
require "hive/web/app_bundle"

class WebAppBundleTest < Minitest::Test
  include HiveTestHelper

  def build_tar(&block)
    io = StringIO.new
    Gem::Package::TarWriter.new(io) { |writer| block.call(writer) }
    io.string
  end

  def each_entry(tar_bytes, dest)
    Gem::Package::TarReader.new(StringIO.new(tar_bytes)) do |tar|
      tar.each { |entry| Hive::Web::AppBundle.extract_entry(entry, dest) }
    end
  end

  def test_github_release_url_uses_canonical_owner_and_repo
    url = Hive::Web::AppBundle.github_release_url
    assert_includes url, "#{Hive::REPO_OWNER}/#{Hive::REPO_NAME}"
    refute_includes url, "asterio"
    assert_includes url, "hive-web-#{Hive::VERSION}.tar.gz"
  end

  def test_extract_entry_writes_a_plain_file
    Dir.mktmpdir do |dest|
      bytes = build_tar { |w| w.add_file("config/application.rb", 0o644) { |f| f.write("ok") } }
      each_entry(bytes, dest)
      assert_equal "ok", File.read(File.join(dest, "config", "application.rb"))
    end
  end

  def test_extract_entry_rejects_path_traversal
    Dir.mktmpdir do |dest|
      bytes = build_tar { |w| w.add_file("../escape.txt", 0o644) { |f| f.write("x") } }
      error = assert_raises(Hive::Error) { each_entry(bytes, dest) }
      assert_match(/unsafe bundle path/, error.message)
      refute File.exist?(File.expand_path("../escape.txt", dest))
    end
  end

  def test_extract_entry_rejects_symlink_member
    Dir.mktmpdir do |dest|
      bytes = build_tar { |w| w.add_symlink("evil", "/etc/passwd", 0o777) }
      error = assert_raises(Hive::Error) { each_entry(bytes, dest) }
      assert_match(/link member/, error.message)
      refute File.symlink?(File.join(dest, "evil"))
    end
  end

  def test_ensure_stamps_version_only_after_successful_bundle_install
    with_hive_home do
      source = seed_source_app
      ran = false
      Hive::Web::AppBundle.ensure!(bundle_url: source, output: nil,
                                   runner: ->(_argv, _env) { ran = true })
      assert ran, "bundle install runner should have run"
      assert Hive::Web::AppBundle.present?
      assert_equal Hive::VERSION, Hive::Web::AppBundle.installed_version
      refute Hive::Web::AppBundle.stale?
    end
  end

  def test_ensure_preserves_the_previous_working_install_when_refresh_fails
    with_hive_home do
      # Seed a working, stamped — but stale — managed bundle.
      app = Hive::Web::AppBundle.app_dir
      FileUtils.mkdir_p(File.join(app, "config"))
      File.write(File.join(app, "config", "application.rb"), "# old app\n")
      File.write(File.join(app, Hive::Web::AppBundle::VERSION_FILE), "0.0.0-old\n")
      assert Hive::Web::AppBundle.stale?, "an old-version stamp must read as stale"

      source = seed_source_app
      assert_raises(Hive::Error) do
        Hive::Web::AppBundle.ensure!(bundle_url: source, output: nil,
                                     runner: ->(_argv, _env) { false })
      end
      # bundle_install! now runs against the staged tmp dir BEFORE the swap, so
      # a Bundler failure never reaches FileUtils.mv — the previous working app
      # (and its stamp) is left untouched instead of being replaced with an
      # unstamped broken bundle.
      assert_equal "# old app\n",
                   File.read(File.join(app, "config", "application.rb")),
                   "a failed refresh must not delete the previous working app"
      assert_equal "0.0.0-old", Hive::Web::AppBundle.installed_version
    end
  end

  def test_ensure_leaves_no_app_dir_when_first_install_fails
    with_hive_home do
      source = seed_source_app
      assert_raises(Hive::Error) do
        Hive::Web::AppBundle.ensure!(bundle_url: source, output: nil,
                                     runner: ->(_argv, _env) { false })
      end
      # With no prior install, a failed bundle install leaves nothing: the
      # half-provisioned tmp is cleaned up, so present? is false rather than a
      # broken bundle masquerading as installed.
      refute Hive::Web::AppBundle.present?,
             "a failed first install must not leave a half-provisioned app dir"
      assert_nil Hive::Web::AppBundle.installed_version
    end
  end

  def test_ensure_unwraps_a_single_top_level_versioned_dir
    with_hive_home do
      # A real GitHub release tarball unpacks to a single versioned wrapper
      # dir (hive-web-X.Y.Z/) around config/application.rb. ensure! must
      # detect that layout and hoist the wrapper's children to the app root.
      source = seed_nested_source_app
      Hive::Web::AppBundle.ensure!(bundle_url: source, output: nil,
                                   runner: ->(_argv, _env) { true })
      assert Hive::Web::AppBundle.present?,
             "a bundle wrapped in a single versioned dir must unwrap to the app root"
      assert_equal "# app\n",
                   File.read(File.join(Hive::Web::AppBundle.app_dir, "config", "application.rb"))
    end
  end

  private

  # Build a "source checkout" whose contents are wrapped in a single
  # top-level versioned directory — the shape `tar -czf` produces for a
  # GitHub release. Exercises ensure!'s nested-unwrap branch.
  def seed_nested_source_app
    src = Dir.mktmpdir("hive-web-nested")
    wrapped = File.join(src, "hive-web-#{Hive::VERSION}")
    FileUtils.mkdir_p(File.join(wrapped, "config"))
    File.write(File.join(wrapped, "config", "application.rb"), "# app\n")
    File.write(File.join(wrapped, "Gemfile"), "source 'https://rubygems.org'\n")
    src
  end

  # Build a minimal "source checkout" the directory branch of
  # fetch_and_extract copies verbatim, including a Gemfile so bundle_install!
  # invokes the injected runner.
  def seed_source_app
    src = Dir.mktmpdir("hive-web-src")
    FileUtils.mkdir_p(File.join(src, "config"))
    File.write(File.join(src, "config", "application.rb"), "# app\n")
    File.write(File.join(src, "Gemfile"), "source 'https://rubygems.org'\n")
    src
  end

  def with_hive_home
    prev = ENV["HIVE_HOME"]
    Dir.mktmpdir("hive-home") do |home|
      ENV["HIVE_HOME"] = home
      yield
    end
  ensure
    if prev.nil?
      ENV.delete("HIVE_HOME")
    else
      ENV["HIVE_HOME"] = prev
    end
  end
end
