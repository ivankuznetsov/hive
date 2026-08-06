require "test_helper"
require "json"
require "open3"
require "rubygems/package"
require "tmpdir"

class GemPackageScriptsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GEMSPEC_PATH = File.join(ROOT, "hive.gemspec")
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

  def test_installed_gem_setup_agents_loads_config_before_dispatch
    skip "gem executable unavailable" unless executable_available?("gem")

    Dir.mktmpdir("hive-installed-cli") do |dir|
      gem_path = File.join(dir, "hive-cli.gem")
      build_out, build_err, build_status = Open3.capture3(
        "gem", "build", GEMSPEC_PATH, "--output", gem_path, chdir: ROOT
      )
      assert build_status.success?,
             "gem build failed\nstdout:\n#{build_out}\nstderr:\n#{build_err}"

      gem_home = File.join(dir, "gems")
      _install_out, install_err, install_status = Open3.capture3(
        "gem", "install", gem_path,
        "--install-dir", gem_home,
        "--bindir", File.join(gem_home, "bin"),
        "--ignore-dependencies", "--no-document"
      )
      assert install_status.success?, "gem install failed: #{install_err}"

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
