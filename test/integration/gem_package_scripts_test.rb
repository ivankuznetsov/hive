require "test_helper"
require "open3"
require "rubygems/package"

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
