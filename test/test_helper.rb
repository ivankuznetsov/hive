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

  # Run a block that may either call `exit N` directly or `raise Hive::Error`.
  # Captures stdout/stderr and returns [out, err, exit_code]. Mirrors what
  # `bin/hive` does in production: a raised Hive::Error is mapped to its
  # exit_code and its message is sent to stderr as `hive: <message>`.
  def with_captured_exit
    out_pipe = StringIO.new
    err_pipe = StringIO.new
    real_stdout = $stdout
    real_stderr = $stderr
    $stdout = out_pipe
    $stderr = err_pipe
    status = 0
    begin
      yield
    rescue SystemExit => e
      status = e.status
    rescue Hive::Error => e
      err_pipe.puts "hive: #{e.message}"
      status = e.exit_code
    ensure
      $stdout = real_stdout
      $stderr = real_stderr
    end
    [ out_pipe.string, err_pipe.string, status ]
  end
end
