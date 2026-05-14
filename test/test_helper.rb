$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "yaml"
require "shellwords"
require "English"
require "hive"

module HiveTestStdinIsolation
  # Keep tests hermetic when the suite is launched from a real terminal:
  # production `hive init` prompts on TTY stdin, but tests that need the
  # interactive path inject their own tty-flagged StringIO explicitly.
  def before_setup
    @hive_original_stdin = $stdin
    $stdin = StringIO.new
    super
  end

  def after_teardown
    super
  ensure
    $stdin = @hive_original_stdin if defined?(@hive_original_stdin)
  end
end

Minitest::Test.include(HiveTestStdinIsolation)

# Shared fixture paths for tests. Constants here so a future move of
# test/fixtures lands in one place instead of every test that needs
# fake-gh / fake-claude. Use as `FAKE_GH_FIXTURE` / `FAKE_CLAUDE_FIXTURE`.
FAKE_GH_FIXTURE = File.expand_path("fixtures/fake-gh", __dir__).freeze
FAKE_CLAUDE_FIXTURE = File.expand_path("fixtures/fake-claude", __dir__).freeze

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
