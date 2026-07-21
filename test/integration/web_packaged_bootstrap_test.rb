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

      # Inject service-manager fakes from the installed gem's real executable,
      # after it has activated the packaged hive-cli. RUBYOPT would leak into
      # Bundler, Rails, and native-extension child Rubies and stop this from
      # exercising the actual bootstrap chain.
      installed_executable = File.join(installed_root, "bin", "hive")
      executable_source = File.read(installed_executable)
      injection = "require ENV.fetch(\"HIVE_SETUP_FIXTURE\") if ENV[\"HIVE_SETUP_FIXTURE\"]\n"
      File.write(
        installed_executable,
        executable_source.sub("require \"hive\"\n", "require \"hive\"\n#{injection}")
      )

      source = File.join(ROOT, "web")
      env = {
        "GEM_HOME" => gem_home,
        "GEM_PATH" => [ gem_home, *Gem.path ].join(File::PATH_SEPARATOR),
        **clean_bundler_environment
      }

      preload = File.join(tmp, "setup-fixtures.rb")
      capture = File.join(tmp, "setup-capture")
      setup_home = File.join(tmp, "setup-home")
      File.write(preload, setup_fixture_source)
      setup_env = env.merge(
        "HIVE_HOME" => setup_home,
        "HIVE_WEB_BUNDLE_URL" => source,
        "HIVE_EXPECTED_CLI_ROOT" => installed_root,
        "HIVE_PACKAGE_CAPTURE" => capture,
        "HIVE_SETUP_FIXTURE" => preload
      )
      stdout, setup_stderr, setup_status = Open3.capture3(
        setup_env, File.join(gem_home, "bin", "hive"), "setup", "--json", "--no-init", "--yes",
        chdir: tmp
      )

      assert setup_status.success?, "installed public setup failed: #{setup_stderr}\n#{stdout}"
      payload = JSON.parse(stdout)
      assert_equal "managed_service", payload.fetch("mode")
      assert_equal true, payload.fetch("ok")
      assert_equal %w[diagnostics agent_skills web_bundle daemon_service web_service web],
                   payload.fetch("phases").map { |phase| phase.fetch("name") }
      agent_skills = payload.fetch("phases").find { |phase| phase.fetch("name") == "agent_skills" }
      refute_equal "consent_required", agent_skills.fetch("classification")
      assert_equal [ installed_root, "daemon", "web" ], File.readlines(capture, chomp: true)
      assert File.file?(File.join(setup_home, "web", "config", "application.rb"))
      assert File.file?(File.join(setup_home, "web", ".hive-web-version"))
      assert Dir.exist?(File.join(setup_home, "web-gems")),
             "the real Bundler install must populate the managed dependency directory"
      assets = File.join(setup_home, "web", "public", "assets", ".manifest.json")
      assert File.file?(assets), "the real Rails assets:precompile must write a manifest"
    end
  end

  private

  def setup_fixture_source
    <<~'RUBY'
      require "hive"
      require "hive/commands/setup"
      require "hive/commands/daemon/service_installer"
      require "hive/commands/web/service_installer"

      packaged_root = Hive::Web::AppBundle.hive_cli_root
      abort "wrong packaged root" unless packaged_root == ENV.fetch("HIVE_EXPECTED_CLI_ROOT")
      abort "missing packaged gemspec" unless File.file?(File.join(packaged_root, "hive.gemspec"))
      File.open(ENV.fetch("HIVE_PACKAGE_CAPTURE"), "a") { |file| file.puts(packaged_root) }

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
        def service_lifecycle_state
          {
            "platform" => "linux", "unit_path" => target_path,
            "service_installed" => true, "service_enabled" => true,
            "service_running" => true, "service_manager_available" => true
          }
        end
        def restart! = true
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
          "platform" => "linux",
          "unit_path" => "/fixture/hive-web.service",
          "service_installed" => true,
          "service_enabled" => true,
          "service_running" => true,
          "service_manager_available" => true,
          "ready" => true,
          "readiness" => "ready"
        }
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
