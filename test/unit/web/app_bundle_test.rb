require "test_helper"
require "rubygems/package"
require "zlib"
require "hive/digest"
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
      captured_env = nil
      with_env("GEM_HOME" => "/installed/gems", "GEM_PATH" => "/installed/gems:/system/gems") do
        Hive::Web::AppBundle.ensure!(bundle_url: source, output: nil,
                                     runner: lambda { |argv, env|
                                       captured_env = env
                                       ran = true
                                       write_compiled_assets(Dir.pwd) if argv == %w[bin/rails assets:precompile]
                                       true
                                     })
      end
      assert ran, "bundle install runner should have run"
      # The managed bundle's Gemfile resolves the hive-cli path gem through
      # HIVE_CLI_ROOT (its ".." holds no gem, and hive-cli is not on
      # rubygems) — without this export the extracted release asset can never
      # bundle-install, so `hive setup`/`hive web install` would fail on
      # every non-source-checkout install.
      assert_equal Hive::Web::AppBundle.hive_cli_root, captured_env["HIVE_CLI_ROOT"]
      assert_nil captured_env["GEM_HOME"]
      assert_nil captured_env["GEM_PATH"]
      assert_equal Hive::Web::AppBundle.dependency_dir, captured_env["BUNDLE_PATH"]
      assert Hive::Web::AppBundle.dependency_dir.start_with?(Hive::Paths.data_home),
             "packaged users must install dependencies beneath their writable data home"
      assert File.file?(File.join(Hive::Web::AppBundle.hive_cli_root, "hive.gemspec")),
             "HIVE_CLI_ROOT must point at the gem root (hive.gemspec present)"
      assert Hive::Web::AppBundle.present?
      assert_equal Hive::VERSION, Hive::Web::AppBundle.installed_version
      refute Hive::Web::AppBundle.stale?
    end
  end

  def test_ensure_precompiles_and_validates_assets_before_stamping
    with_hive_home do
      calls = []
      Hive::Web::AppBundle.ensure!(
        bundle_url: seed_source_app,
        output: nil,
        runner: lambda { |argv, env|
          calls << [ argv, env, Dir.pwd ]
          write_compiled_assets(Dir.pwd) if argv == %w[bin/rails assets:precompile]
          true
        }
      )

      assert_equal [ %w[bundle install], %w[bin/rails assets:precompile] ], calls.map(&:first)
      assert calls.all? { |_argv, _env, dir| dir.include?(".tmp.") }
      assert_equal "production", calls.last[1]["RAILS_ENV"]
      assert Hive::Web::AppBundle.assets_ready?
      assert_equal Hive::VERSION, Hive::Web::AppBundle.installed_version
    end
  end

  def test_same_version_install_with_missing_assets_is_repaired
    with_hive_home do
      app = Hive::Web::AppBundle.app_dir
      FileUtils.mkdir_p(File.join(app, "config"))
      File.write(File.join(app, "config", "application.rb"), "# broken\n")
      File.write(File.join(app, Hive::Web::AppBundle::VERSION_FILE), "#{Hive::VERSION}\n")

      calls = []
      Hive::Web::AppBundle.ensure!(
        bundle_url: seed_source_app,
        output: nil,
        runner: lambda { |argv, _env|
          calls << argv
          write_compiled_assets(Dir.pwd) if argv == %w[bin/rails assets:precompile]
          true
        }
      )

      assert_includes calls, %w[bin/rails assets:precompile]
      assert Hive::Web::AppBundle.assets_ready?
    end
  end

  def test_asset_precompile_without_output_preserves_previous_bundle
    with_hive_home do
      app = Hive::Web::AppBundle.app_dir
      FileUtils.mkdir_p(File.join(app, "config"))
      File.write(File.join(app, "config", "application.rb"), "# old\n")
      File.write(File.join(app, Hive::Web::AppBundle::VERSION_FILE), "old\n")

      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.ensure!(
          bundle_url: seed_source_app, output: nil, runner: ->(_argv, _env) { true }
        )
      end

      assert_match(/asset precompile produced no usable/, error.message)
      assert_equal "# old\n", File.read(File.join(app, "config", "application.rb"))
      assert_equal "old", Hive::Web::AppBundle.installed_version
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
                                   runner: successful_prepare_runner)
      assert Hive::Web::AppBundle.present?,
             "a bundle wrapped in a single versioned dir must unwrap to the app root"
      assert_equal "# app\n",
                   File.read(File.join(Hive::Web::AppBundle.app_dir, "config", "application.rb"))
    end
  end

  def test_ensure_raises_when_bundle_url_is_empty
    with_hive_home do
      refute Hive::Web::AppBundle.present?, "precondition: no managed app installed yet"
      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.ensure!(bundle_url: "", output: nil, runner: ->(_argv, _env) { true })
      end
      assert_match(/managed web app is missing/, error.message)
      assert_match(/HIVE_WEB_BUNDLE_URL/, error.message)
    end
  end

  def test_ensure_raises_when_bundle_lacks_config_application_rb
    with_hive_home do
      # A source dir with content but no config/application.rb (and no nested
      # wrapper that contains one) must be rejected rather than installed.
      src = Dir.mktmpdir("hive-web-bad")
      FileUtils.mkdir_p(File.join(src, "lib"))
      File.write(File.join(src, "lib", "thing.rb"), "# not the app\n")

      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.ensure!(bundle_url: src, output: nil, runner: ->(_argv, _env) { true })
      end
      assert_match(/does not contain config\/application\.rb/, error.message)
      refute Hive::Web::AppBundle.present?, "a rejected bundle must not leave a managed app behind"
    end
  end

  def test_bundle_install_rejects_package_root_without_gemspec
    Dir.mktmpdir("hive-web-app") do |app|
      Dir.mktmpdir("hive-cli-root") do |root|
        File.write(File.join(app, "Gemfile"), "source 'https://rubygems.org'\n")
        with_replaced_singleton_method(Hive::Web::AppBundle, :hive_cli_root, -> { root }) do
          error = assert_raises(Hive::Error) do
            Hive::Web::AppBundle.bundle_install!(dir: app, output: nil, runner: ->(*) { flunk })
          end
          assert_match(/has no hive\.gemspec/, error.message)
        end
      end
    end
  end

  def test_default_bundle_url_prefers_env_override_then_falls_back_to_release_url
    with_env("HIVE_WEB_BUNDLE_URL" => "https://example.test/custom-bundle.tar.gz") do
      assert_equal "https://example.test/custom-bundle.tar.gz", Hive::Web::AppBundle.default_bundle_url
    end
    with_env("HIVE_WEB_BUNDLE_URL" => nil) do
      assert_equal Hive::Web::AppBundle.github_release_url, Hive::Web::AppBundle.default_bundle_url
    end
  end

  def test_fetch_and_extract_downloads_gunzips_and_unpacks_via_uri_open
    with_hive_home do
      # Build a gzipped tar in memory containing a DIRECTORY entry (exercises
      # the entry.directory? branch) plus config/application.rb + a Gemfile.
      gz_bytes = build_gzipped_tar do |w|
        w.mkdir("config", 0o755)
        w.add_file("config/application.rb", 0o644) { |f| f.write("# fetched app\n") }
        w.add_file("Gemfile", 0o644) { |f| f.write("source 'https://rubygems.org'\n") }
      end

      ran = false
      opened_url = nil
      with_replaced_singleton_method(URI, :open, lambda { |url, **_opts|
        opened_url = url
        StringIO.new(gz_bytes)
      }) do
        Hive::Web::AppBundle.ensure!(bundle_url: "https://example.test/bundle.tar.gz",
                                     bundle_sha256: Digest::SHA256.hexdigest(gz_bytes),
                                     output: nil, runner: lambda { |argv, _env|
                                       ran = true
                                       write_compiled_assets(Dir.pwd) if argv == %w[bin/rails assets:precompile]
                                       true
                                     })
      end

      assert_equal "https://example.test/bundle.tar.gz", opened_url,
                   "fetch must route the bundle url through the timeout-bounded URI.open"
      assert ran, "bundle install runner should have run after a successful fetch"
      assert Hive::Web::AppBundle.present?, "the gunzipped tar must unpack to a present app"
      assert_equal "# fetched app\n",
                   File.read(File.join(Hive::Web::AppBundle.app_dir, "config", "application.rb"))
      assert File.directory?(File.join(Hive::Web::AppBundle.app_dir, "config")),
             "the directory tar entry must have been created via mkdir_p"
    end
  end


  def test_custom_remote_requires_digest_before_downloading
    opened = false
    with_replaced_singleton_method(URI, :open, ->(*) { opened = true }) do
      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.ensure!(
          bundle_url: "https://example.test/custom.tar.gz",
          bundle_sha256: nil,
          output: nil,
          runner: ->(*) { true }
        )
      end

      assert_match(/HIVE_WEB_BUNDLE_SHA256/, error.message)
      refute opened, "missing digest must fail before untrusted bytes are downloaded"
    end
  end

  def test_custom_remote_rejects_invalid_url
    error = assert_raises(Hive::Error) do
      Hive::Web::AppBundle.ensure!(
        bundle_url: "https://exa mple.test/bundle.tar.gz",
        bundle_sha256: "0" * 64,
        output: nil,
        runner: ->(*) { flunk }
      )
    end

    assert_match(/invalid managed bundle URL/, error.message)
  end

  def test_custom_remote_digest_mismatch_fails_before_extraction_or_bundler
    gz_bytes = build_gzipped_tar do |w|
      w.add_file("config/application.rb", 0o644) { |f| f.write("# app\n") }
      w.add_file("Gemfile", 0o644) { |f| f.write("source 'https://rubygems.org'\n") }
    end
    ran = false
    with_replaced_singleton_method(URI, :open, ->(*) { StringIO.new(gz_bytes) }) do
      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.ensure!(
          bundle_url: "https://example.test/custom.tar.gz",
          bundle_sha256: "0" * 64,
          output: nil,
          runner: ->(*) { ran = true }
        )
      end

      assert_match(/digest mismatch/, error.message)
      refute ran, "tampered archive must never reach Bundler"
    end
  end

  def test_default_release_verifies_signed_manifest_identity_and_exact_digest
    gz_bytes = build_gzipped_tar do |w|
      w.add_file("config/application.rb", 0o644) { |f| f.write("# app\n") }
      w.add_file("Gemfile", 0o644) { |f| f.write("source 'https://rubygems.org'\n") }
    end
    digest = Digest::SHA256.hexdigest(gz_bytes)
    downloads = []
    verifier_calls = []
    downloader = lambda do |url, path|
      downloads << File.basename(URI.parse(url).path)
      content = case File.basename(path)
      when /hive-web/ then gz_bytes
      when "SHA256SUMS" then "#{digest}  hive-web-#{Hive::VERSION}.tar.gz\n"
      when "SHA256SUMS.sig" then "signature"
      when "SHA256SUMS.pem" then "certificate"
      else flunk "unexpected download #{url}"
      end
      File.binwrite(path, content)
    end
    verifier = lambda do |manifest:, signature:, certificate:, identity:|
      verifier_calls << [ manifest, signature, certificate, identity ]
      true
    end

    with_hive_home do
      Hive::Web::AppBundle.ensure!(
        downloader: downloader,
        verifier: verifier,
        output: nil,
        runner: successful_prepare_runner
      )
    end

    assert_equal %W[
      hive-web-#{Hive::VERSION}.tar.gz SHA256SUMS SHA256SUMS.sig SHA256SUMS.pem
    ], downloads
    assert_equal 1, verifier_calls.length
    assert_equal(
      "^https://github\\.com/ivankuznetsov/hive/\\.github/workflows/" \
      "release\\.yml@refs/tags/v#{Regexp.escape(Hive::VERSION)}$",
      verifier_calls.first.last
    )
  end

  def test_default_release_digest_mismatch_fails_before_extraction_or_bundler
    gz_bytes = build_gzipped_tar do |writer|
      writer.add_file("config/application.rb", 0o644) { |file| file.write("# app\n") }
      writer.add_file("Gemfile", 0o644) { |file| file.write("source 'https://rubygems.org'\n") }
    end
    downloader = lambda do |url, path|
      content = case File.basename(URI.parse(url).path)
      when /hive-web/ then gz_bytes
      when "SHA256SUMS" then "#{'0' * 64}  hive-web-#{Hive::VERSION}.tar.gz\n"
      else "signed fixture"
      end
      File.binwrite(path, content)
    end
    ran = false

    with_hive_home do
      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.ensure!(
          downloader: downloader,
          verifier: ->(**) { true },
          output: nil,
          runner: ->(*) { ran = true }
        )
      end
      assert_match(/digest mismatch/, error.message)
      refute ran, "a modified default release archive must never reach Bundler"
      refute Hive::Web::AppBundle.present?
    end
  end

  def test_default_release_requires_exactly_one_manifest_row
    Dir.mktmpdir("hive-web-manifest") do |dir|
      archive = File.join(dir, "hive-web-#{Hive::VERSION}.tar.gz")
      File.binwrite(archive, "archive")
      downloader = lambda do |_url, path|
        content = File.basename(path) == "SHA256SUMS" ? "no matching row\n" : "fixture"
        File.binwrite(path, content)
      end

      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.verify_default_release!(
          bundle_url: Hive::Web::AppBundle.github_release_url,
          archive_path: archive,
          download_dir: dir,
          downloader: downloader,
          verifier: ->(**) { true }
        )
      end
      assert_match(/exactly one digest/, error.message)
    end
  end

  def test_default_release_rejects_failed_signature_verification
    Dir.mktmpdir("hive-web-signature") do |dir|
      archive = File.join(dir, "hive-web-#{Hive::VERSION}.tar.gz")
      File.binwrite(archive, "archive")
      downloader = ->(_url, path) { File.binwrite(path, "fixture") }

      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.verify_default_release!(
          bundle_url: Hive::Web::AppBundle.github_release_url,
          archive_path: archive,
          download_dir: dir,
          downloader: downloader,
          verifier: ->(**) { false }
        )
      end
      assert_match(/signed release manifest verification failed/, error.message)
    end
  end

  def test_default_signature_verification_requires_cosign
    with_replaced_singleton_method(Hive::InvokedBinary, :which, ->(_name) { }) do
      error = assert_raises(Hive::Error) do
        Hive::Web::AppBundle.verify_manifest_signature(
          manifest: "manifest",
          signature: "signature",
          certificate: "certificate",
          identity: "identity"
        )
      end
      assert_match(/cosign is required/, error.message)
    end
  end

  def test_default_signature_verification_runs_cosign_and_reports_failure_stderr
    status = Object.new
    status.define_singleton_method(:success?) { false }
    captured = nil

    _stdout, stderr = capture_io do
      with_replaced_singleton_method(Hive::InvokedBinary, :which, ->(_name) { "/usr/bin/cosign" }) do
        runner = lambda { |*argv, timeout_sec:|
          captured = [ *argv, timeout_sec ]
          [ "", "identity mismatch", status ]
        }
        refute Hive::Web::AppBundle.verify_manifest_signature(
          manifest: "manifest", signature: "signature", certificate: "certificate",
          identity: "identity", runner: runner
        )
      end
    end

    assert_equal "/usr/bin/cosign", captured.first
    assert_includes captured, "--certificate-identity-regexp"
    assert_equal Hive::Web::AppBundle::COSIGN_TIMEOUT_SEC, captured.last
    assert_includes stderr, "identity mismatch"
  end

  def test_default_signature_verification_accepts_cosign_success
    status = Object.new
    status.define_singleton_method(:success?) { true }

    with_replaced_singleton_method(Hive::InvokedBinary, :which, ->(_name) { "/usr/bin/cosign" }) do
      assert Hive::Web::AppBundle.verify_manifest_signature(
        manifest: "manifest", signature: "signature", certificate: "certificate",
        identity: "identity", runner: ->(*_argv, timeout_sec:) { [ "", "", status ] }
      )
    end
  end

  def test_bounded_capture_terminates_a_stuck_verifier
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Hive::Error) do
      Hive::Web::AppBundle.capture3_bounded(
        RbConfig.ruby, "-e", "sleep 30", timeout_sec: 0.05
      )
    end

    assert_match(/timed out/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  end

  private

  def build_gzipped_tar(&block)
    tar = build_tar(&block)
    io = StringIO.new
    gz = Zlib::GzipWriter.new(io)
    gz.write(tar)
    gz.close
    io.string
  end


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

  def successful_prepare_runner
    lambda do |argv, _env|
      write_compiled_assets(Dir.pwd) if argv == %w[bin/rails assets:precompile]
      true
    end
  end

  def write_compiled_assets(dir)
    assets = File.join(dir, "public", "assets")
    FileUtils.mkdir_p(assets)
    File.write(File.join(assets, "application-test.css"), "body {}\n")
    File.write(File.join(assets, "application-test.js"), "export {}\n")
    File.write(
      File.join(assets, ".manifest.json"),
      JSON.generate(
        "application.css" => { "digested_path" => "application-test.css" },
        "application.js" => { "digested_path" => "application-test.js" }
      )
    )
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
