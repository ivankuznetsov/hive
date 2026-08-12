require "test_helper"
require "json"
require "open3"
require "rubygems/package"
require "tmpdir"

class GemPackageScriptsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GEMSPEC_PATH = File.join(ROOT, "hive.gemspec")
  AGENT_CLI_RUNTIME_ROOT = File.join(ROOT, "components", "agent-cli-runtime")
  AGENT_CLI_RUNTIME_GEMSPEC_PATH = File.join(AGENT_CLI_RUNTIME_ROOT, "agent-cli-runtime.gemspec")
  SCRIPT_REFERENCE_FILES = [
    "lib/hive/claude_launcher.rb",
    "lib/hive/stop_hook_installer.rb"
  ].freeze

  def test_built_gem_contains_all_claude_launcher_script_references
    skip "gem executable unavailable" unless executable_available?("gem")

    referenced_scripts = claude_launcher_script_references

    refute_empty referenced_scripts,
                 "script-reference guard must not pass without discovering scripts"
    referenced_scripts.each do |path|
      assert File.exist?(File.join(ROOT, path)), "referenced script is missing from source: #{path}"
    end

    Dir.mktmpdir("hive-test") do |dir|
      gem_path = File.join(dir, "hive-cli.gem")
      stdout, stderr, status = Open3.capture3("gem", "build", GEMSPEC_PATH, "--output", gem_path, chdir: ROOT)

      assert status.success?,
             "gem build failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"

      packaged_files = Gem::Package.new(gem_path).spec.files
      referenced_scripts.each do |path|
        assert_includes packaged_files, path
      end
    end
  end

  def test_installed_gem_resolves_agent_cli_runtime_and_loads_config_before_dispatch
    skip "gem executable unavailable" unless executable_available?("gem")

    Dir.mktmpdir("hive-installed-cli") do |dir|
      gem_path = File.join(dir, "hive-cli.gem")
      runtime_gem_path = File.join(dir, "agent-cli-runtime.gem")
      runtime_build_out, runtime_build_err, runtime_build_status = Open3.capture3(
        "gem", "build", AGENT_CLI_RUNTIME_GEMSPEC_PATH,
        "--output", runtime_gem_path,
        chdir: AGENT_CLI_RUNTIME_ROOT
      )
      assert runtime_build_status.success?,
             "agent-cli-runtime gem build failed\nstdout:\n#{runtime_build_out}\nstderr:\n#{runtime_build_err}"

      build_out, build_err, build_status = Open3.capture3(
        "gem", "build", GEMSPEC_PATH, "--output", gem_path, chdir: ROOT
      )
      assert build_status.success?,
             "gem build failed\nstdout:\n#{build_out}\nstderr:\n#{build_err}"

      gem_home = File.join(dir, "gems")
      # RubyGems' ensure_writable_dir mkdirs --bindir NON-recursively, and the
      # suite runs under `bundle exec`, where Bundler overrides Gem.dir so the
      # GEM_HOME below is never created for us. Without this the first install
      # dies with ENOENT on <gem_home>/bin.
      FileUtils.mkdir_p(File.join(gem_home, "bin"))
      install_env = {
        "GEM_HOME" => gem_home,
        "GEM_PATH" => [ gem_home, *Gem.path ].uniq.join(File::PATH_SEPARATOR)
      }
      runtime_install_out, runtime_install_err, runtime_install_status = Open3.capture3(
        install_env,
        "gem", "install", runtime_gem_path,
        "--bindir", File.join(gem_home, "bin"),
        "--local", "--no-document"
      )
      assert runtime_install_status.success?,
             "agent-cli-runtime gem install failed\nstdout:\n#{runtime_install_out}\nstderr:\n#{runtime_install_err}"

      install_out, install_err, install_status = Open3.capture3(
        install_env,
        "gem", "install", gem_path,
        "--bindir", File.join(gem_home, "bin"),
        "--local", "--no-document"
      )
      assert install_status.success?,
             "hive gem install failed\nstdout:\n#{install_out}\nstderr:\n#{install_err}"

      home = File.join(dir, "home")
      FileUtils.mkdir_p(home)
      env = {
        "GEM_HOME" => gem_home,
        "GEM_PATH" => [ gem_home, *Gem.path ].uniq.join(File::PATH_SEPARATOR),
        "HOME" => home,
        "HIVE_HOME" => File.join(home, ".local", "state", "hive"),
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
        "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
        "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
      }
      version_stdout, version_stderr, version_status = Open3.capture3(
        env,
        File.join(gem_home, "bin", "hive"), "--version",
        chdir: dir
      )
      assert version_status.success?, version_stderr
      assert_equal Hive::VERSION, version_stdout.strip

      runtime_stdout, runtime_stderr, runtime_status = Open3.capture3(
        env,
        File.join(gem_home, "bin", "agent-runtime"), "--version",
        chdir: dir
      )
      assert runtime_status.success?, runtime_stderr
      assert_equal AgentCliRuntime::VERSION, runtime_stdout.strip

      stdout, stderr, status = Open3.capture3(
        env,
        File.join(gem_home, "bin", "hive"),
        "setup-agents", "--yes", "--json", "--agent", "not-configured",
        chdir: dir
      )

      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus, stderr
      payload = JSON.parse(stdout)
      assert_equal "invalid_config", payload.fetch("classification")
      assert_match(/agent filter\(s\) not configured/, payload.fetch("message"))
      refute_match(/uninitialized constant Hive::Config/, stderr)
    end
  end

  private

  def claude_launcher_script_references
    SCRIPT_REFERENCE_FILES.flat_map do |path|
      source = File.read(File.join(ROOT, path), encoding: "UTF-8")
      source.scan(%r{scripts/[^"')\s]+\.sh}).map { |script| "lib/hive/#{script}" }
    end.uniq.sort
  end

  def executable_available?(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, name)
      File.file?(path) && File.executable?(path)
    end
  end
end
