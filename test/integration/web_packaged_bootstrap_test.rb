require "test_helper"
require "json"
require "open3"
require "rbconfig"

class WebPackagedBootstrapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_installed_gem_root_bootstraps_without_parent_checkout_gemspec
    Dir.mktmpdir("hive-packaged-web") do |tmp|
      gem_file = File.join(tmp, "hive-cli.gem")
      build_out, build_err, build_status = Open3.capture3(
        "gem", "build", File.join(ROOT, "hive.gemspec"), "--output", gem_file,
        chdir: ROOT
      )
      assert build_status.success?, "gem build failed: #{build_out}\n#{build_err}"

      gem_home = File.join(tmp, "gems")
      _out, install_err, install_status = Open3.capture3(
        "gem", "install", gem_file, "--install-dir", gem_home,
        "--bindir", File.join(gem_home, "bin"), "--ignore-dependencies", "--no-document"
      )
      assert install_status.success?, "gem install failed: #{install_err}"

      installed_root = Dir[File.join(gem_home, "gems", "hive-cli-*")].fetch(0)
      assert File.file?(File.join(installed_root, "hive.gemspec"))
      refute File.file?(File.expand_path("../hive.gemspec", installed_root)),
             "fixture must not consult an enclosing source checkout"

      script = <<~'RUBY'
        require "hive/web/app_bundle"
        source = ARGV.fetch(0)
        captured = nil
        Hive::Web::AppBundle.ensure!(
          bundle_url: source,
          output: nil,
          runner: ->(_argv, env) { captured = env; true }
        )
        root = Hive::Web::AppBundle.hive_cli_root
        abort "wrong root" unless root == ARGV.fetch(1)
        abort "missing packaged gemspec" unless File.file?(File.join(root, "hive.gemspec"))
        abort "wrong bundler root" unless captured.fetch("HIVE_CLI_ROOT") == root
      RUBY
      source = File.join(tmp, "web-source")
      FileUtils.mkdir_p(File.join(source, "config"))
      File.write(File.join(source, "config", "application.rb"), "# app\n")
      File.write(File.join(source, "Gemfile"), "source 'https://rubygems.org'\n")
      env = {
        "GEM_HOME" => gem_home,
        "GEM_PATH" => [ gem_home, *Gem.path ].join(File::PATH_SEPARATOR),
        "HIVE_HOME" => File.join(tmp, "hive-home"),
        **clean_bundler_environment
      }
      _stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, "-I#{File.join(installed_root, 'lib')}", "-e", script,
        source, installed_root,
        chdir: tmp
      )

      assert status.success?, "installed bootstrap failed: #{stderr}"

      preload = File.join(tmp, "setup-fixtures.rb")
      capture = File.join(tmp, "setup-capture")
      File.write(preload, setup_fixture_source)
      setup_env = env.merge(
        "HIVE_HOME" => File.join(tmp, "setup-home"),
        "HIVE_WEB_BUNDLE_URL" => source,
        "HIVE_EXPECTED_CLI_ROOT" => installed_root,
        "HIVE_PACKAGE_CAPTURE" => capture,
        "RUBYOPT" => "-r#{preload}"
      )
      stdout, setup_stderr, setup_status = Open3.capture3(
        setup_env, File.join(gem_home, "bin", "hive"), "setup", "--json", "--no-init",
        chdir: tmp
      )

      assert setup_status.success?, "installed public setup failed: #{setup_stderr}\n#{stdout}"
      payload = JSON.parse(stdout)
      assert_equal "managed_service", payload.fetch("mode")
      assert_equal true, payload.fetch("ok")
      assert_equal %w[diagnostics web_bundle daemon_service web_service web],
                   payload.fetch("phases").map { |phase| phase.fetch("name") }
      assert_equal [ installed_root, "daemon", "web" ], File.readlines(capture, chomp: true)
    end
  end

  private

  def setup_fixture_source
    <<~'RUBY'
      require "hive"
      require "hive/commands/setup"
      require "hive/commands/daemon/service_installer"
      require "hive/commands/web/service_installer"

      class PackagedSetupDiagnostics
        def run = self
        def ok? = true
        def results = []
        def to_h = { "results" => [] }
      end

      class PackagedSetupOutcome
        def success? = true
        def failed? = false
        def drifted? = false
        def wire_outcome = "written"
      end

      class PackagedSetupInstaller
        attr_reader :messages

        def initialize(label)
          @label = label
          @messages = []
        end

        def install!(**)
          File.open(ENV.fetch("HIVE_PACKAGE_CAPTURE"), "a") { |file| file.puts(@label) }
          PackagedSetupOutcome.new
        end

        def target_path = "/fixture/hive-#{@label}.service"
      end

      Hive::Setup::Diagnostics.define_singleton_method(:new) { PackagedSetupDiagnostics.new }
      Hive::Commands::Daemon::ServiceInstaller.define_singleton_method(:new) do |**|
        PackagedSetupInstaller.new("daemon")
      end
      Hive::Commands::Web::ServiceInstaller.define_singleton_method(:new) do |**|
        PackagedSetupInstaller.new("web")
      end
      Hive::Config.define_singleton_method(:load_global_web) do
        { "bind" => "127.0.0.1", "port" => 4567 }
      end
      Hive::Web::ServiceStatus.define_singleton_method(:snapshot) do |**|
        {
          "url" => "http://127.0.0.1:4567",
          "service_installed" => true,
          "service_enabled" => true,
          "service_running" => true,
          "ready" => true,
          "readiness" => "ready"
        }
      end
      Hive::Web::AppBundle.define_singleton_method(:bundle_install!) do |dir:, **|
        root = hive_cli_root
        abort "wrong packaged root" unless root == ENV.fetch("HIVE_EXPECTED_CLI_ROOT")
        abort "missing packaged gemspec" unless File.file?(File.join(root, "hive.gemspec"))
        File.open(ENV.fetch("HIVE_PACKAGE_CAPTURE"), "a") { |file| file.puts(root) }
        dir
      end
    RUBY
  end

  def clean_bundler_environment
    ENV.keys.grep(/\A(?:BUNDLE|BUNDLER_)/).to_h { |name| [ name, nil ] }.merge(
      "RUBYLIB" => nil,
      "RUBYOPT" => nil
    )
  end
end
