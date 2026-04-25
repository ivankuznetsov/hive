$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "shellwords"
require "English"
require "hive"

module HiveTestHelper
  def with_tmp_dir(&block)
    Dir.mktmpdir("hive-test", &block)
  end

  def with_tmp_git_repo
    with_tmp_dir do |dir|
      run!("git", "-C", dir, "init", "-b", "master", "--quiet")
      run!("git", "-C", dir, "config", "user.email", "test@example.com")
      run!("git", "-C", dir, "config", "user.name", "Test")
      run!("git", "-C", dir, "config", "commit.gpgsign", "false")
      File.write(File.join(dir, "README.md"), "test\n")
      run!("git", "-C", dir, "add", ".")
      run!("git", "-C", dir, "commit", "-m", "initial", "--quiet")
      yield(dir)
    end
  end

  def run!(*cmd)
    out = `#{cmd.shelljoin} 2>&1`
    raise "command failed: #{cmd.shelljoin}\n#{out}" unless $CHILD_STATUS&.success?

    out
  end

  def with_tmp_global_config
    Dir.mktmpdir("hive-global") do |dir|
      old = ENV["HIVE_HOME"]
      ENV["HIVE_HOME"] = dir
      File.write(File.join(dir, "config.yml"), { "registered_projects" => [] }.to_yaml)
      begin
        yield(dir)
      ensure
        ENV["HIVE_HOME"] = old
      end
    end
  end
end
